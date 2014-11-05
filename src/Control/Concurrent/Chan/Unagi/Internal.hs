{-# LANGUAGE BangPatterns , DeriveDataTypeable, CPP #-}
module Control.Concurrent.Chan.Unagi.Internal
#ifdef NOT_x86
    {-# WARNING "This library is unlikely to perform well on architectures without a fetch-and-add instruction" #-}
#endif
    (sEGMENT_LENGTH
    , InChan(..), OutChan(..), ChanEnd(..), StreamSegment, Cell(..), Stream(..)
    , NextSegment(..), StreamHead(..)
    , newChanStarting, writeChan, readChan, readChanOnException
    , dupChan
    )
    where

-- Internals exposed for testing.

import Control.Concurrent.MVar
import Data.IORef
import Control.Exception
import Control.Monad.Primitive(RealWorld)
import Data.Atomics.Counter.Fat
import Data.Atomics
import qualified Data.Primitive as P
import Control.Monad
import Control.Applicative
import Data.Bits
import Data.Typeable(Typeable)
import GHC.Exts(inline)

import Control.Concurrent.Chan.Unagi.Constants


-- | The write end of a channel created with 'newChan'.
data InChan a = InChan !(Ticket (Cell a)) !(ChanEnd a)
    deriving Typeable

-- | The read end of a channel created with 'newChan'.
newtype OutChan a = OutChan (ChanEnd a)
    deriving Typeable

instance Eq (InChan a) where
    (InChan _ (ChanEnd _ _ headA)) == (InChan _ (ChanEnd _ _ headB))
        = headA == headB
instance Eq (OutChan a) where
    (OutChan (ChanEnd _ _ headA)) == (OutChan (ChanEnd _ _ headB))
        = headA == headB

-- TODO POTENTIAL CPP FLAGS (or functions)
--   - Strict element (or lazy? maybe also expose a writeChan' when relevant?)
--   - sEGMENT_LENGTH
--   - reads that clear the element immediately (or export as a special function?)

-- InChan & OutChan are mostly identical, sharing a stream, but with
-- independent counters
data ChanEnd a = 
           -- an efficient producer of segments of length sEGMENT_LENGTH:
    ChanEnd !(SegSource a)
            -- Both Chan ends must start with the same counter value.
            !AtomicCounter 
            -- the stream head; this must never point to a segment whose offset
            -- is greater than the counter value
            !(IORef (StreamHead a))
    deriving Typeable

data StreamHead a = StreamHead !Int !(Stream a)

--TODO later see if we get a benefit from the small array primops in 7.10,
--     which omit card-marking overhead and might have faster clone.
type StreamSegment a = P.MutableArray RealWorld (Cell a)

-- TRANSITIONS and POSSIBLE VALUES:
--   During Read:
--     Empty   -> Blocking
--     Written
--     Blocking (only when dupChan used)
--   During Write:
--     Empty   -> Written 
--     Blocking
data Cell a = Empty | Written a | Blocking !(MVar a)


-- NOTE In general we'll have two segments allocated at any given time in
-- addition to the segment template, so in the worst case, when the program
-- exits we will have allocated ~ 3 segments extra memory than was actually
-- required.

data Stream a = 
    Stream !(StreamSegment a)
           -- The next segment in the stream; new segments are allocated and
           -- put here as we go, with threads cooperating to allocate new
           -- segments:
           !(IORef (NextSegment a))

data NextSegment a = NoSegment | Next !(Stream a)

-- we expose `startingCellOffset` for debugging correct behavior with overflow:
newChanStarting :: Int -> IO (InChan a, OutChan a)
{-# INLINE newChanStarting #-}
newChanStarting !startingCellOffset = do
    segSource <- newSegmentSource
    firstSeg <- segSource
    -- collect a ticket to save for writer CAS
    savedEmptyTkt <- readArrayElem firstSeg 0
    stream <- Stream firstSeg <$> newIORef NoSegment
    let end = ChanEnd segSource 
                  <$> newCounter (startingCellOffset - 1)
                  <*> newIORef (StreamHead startingCellOffset stream)
    liftA2 (,) (InChan savedEmptyTkt <$> end) (OutChan <$> end)

-- | Duplicate a chan: the returned @OutChan@ begins empty, but data written to
-- the argument @InChan@ from then on will be available from both the original
-- @OutChan@ and the one returned here, creating a kind of broadcast channel.
dupChan :: InChan a -> IO (OutChan a)
{-# INLINE dupChan #-}
dupChan (InChan _ (ChanEnd segSource counter streamHead)) = do
    hLoc <- readIORef streamHead
    loadLoadBarrier  -- NOTE [1]
    wCount <- readCounter counter
    
    counter' <- newCounter wCount 
    streamHead' <- newIORef hLoc
    return $ OutChan (ChanEnd segSource counter' streamHead')
  -- [1] We must read the streamHead before inspecting the counter; otherwise,
  -- as writers write, the stream head pointer may advance past the cell
  -- indicated by wCount. For the corresponding store-store barrier see [*] in
  -- moveToNextCell

-- | Write a value to the channel.
writeChan :: InChan a -> a -> IO ()
{-# INLINE writeChan #-}
writeChan (InChan savedEmptyTkt ce@(ChanEnd segSource _ _)) = \a-> mask_ $ do 
    (segIx, (Stream seg next)) <- moveToNextCell ce
    (success,nonEmptyTkt) <- casArrayElem seg segIx savedEmptyTkt (Written a)
    -- try to pre-allocate next segment; NOTE [1]
    when (segIx == 0) $ void $
      waitingAdvanceStream next segSource 0
    when (not success) $
        case peekTicket nonEmptyTkt of
             Blocking v -> putMVar v a
             Empty      -> error "Stored Empty Ticket went stale!" -- NOTE [2]
             Written _  -> error "Nearly Impossible! Expected Blocking"
  -- [1] the writer which arrives first to the first cell of a new segment is
  -- tasked (somewhat arbitrarily) with trying to pre-allocate the *next*
  -- segment hopefully ahead of any readers or writers who might need it. This
  -- will race with any reader *or* writer that tries to read the next segment
  -- and finds it's empty (see `waitingAdvanceStream`); when this wins
  -- (hopefully the vast majority of the time) we avoid a throughput hit.
  --
  -- [2] this assumes that the compiler is statically-allocating Empty, sharing
  -- the constructor among all uses, and that it never moves it between
  -- checking the pointer stored in the array and checking the pointer in the
  -- cached Any Empty value. If this is incorrect then the Ticket approach to
  -- CAS is equally incorrect (though maybe less likely to fail).


-- We would like our queue to behave like Chan in that an async exception
-- raised in a reader known to be blocked or about to block on an empty queue
-- never results in a lost message; this matches our simple intuition about the
-- mechanics of a queue: if you're last in line for a cupcake and have to leave
-- you wouldn't expect the cake that would have gone to you to disappear.
--
-- But there are other systems that a busy cake shop might use that you could
-- easily imagine resulting in a lost cake, and that's a different question
-- from whether cakes are given to well-behaved customers in the order they
-- came out of the oven, or whether a customer leaving at the wrong moment
-- might cause the cake shop to burn down...
readChanOnExceptionUnmasked :: (IO a -> IO a) -> OutChan a -> IO a
{-# INLINE readChanOnExceptionUnmasked #-}
readChanOnExceptionUnmasked h = \(OutChan ce)-> do
    (segIx, (Stream seg _)) <- moveToNextCell ce
    cellTkt <- readArrayElem seg segIx
    case peekTicket cellTkt of
         Written a -> return a
         Empty -> do
            v <- newEmptyMVar
            (success,elseWrittenCell) <- casArrayElem seg segIx cellTkt (Blocking v)
            if success 
              then readBlocking v
              else case peekTicket elseWrittenCell of
                        -- In the meantime a writer has written. Good!
                        Written a -> return a
                        -- ...or a dupChan reader initiated blocking:
                        Blocking v2 -> readBlocking v2
                        _ -> error "Impossible! Expecting Written or Blocking"
         Blocking v -> readBlocking v
  -- N.B. must use `readMVar` here to support `dupChan`:
  where readBlocking v = inline h $ readMVar v 


-- | Read an element from the chan, blocking if the chan is empty.
--
-- /Note re. exceptions/: When an async exception is raised during a @readChan@ 
-- the message that the read would have returned is likely to be lost, even when
-- the read is known to be blocked on an empty queue. If you need to handle
-- this scenario, you can use 'readChanOnException'.
readChan :: OutChan a -> IO a
{-# INLINE readChan #-}
readChan = readChanOnExceptionUnmasked id

-- | Like 'readChan' but allows recovery of the queue element which would have
-- been read, in the case that an async exception is raised during the read. To
-- be precise exceptions are raised, and the handler run, only when
-- @readChanOnException@ is blocking.
--
-- The second argument is a handler that takes a blocking IO action returning
-- the element, and performs some recovery action.  When the handler is called,
-- the passed @IO a@ is the only way to access the element.
readChanOnException :: OutChan a -> (IO a -> IO ()) -> IO a
{-# INLINE readChanOnException #-}
readChanOnException c h = mask_ $ 
    readChanOnExceptionUnmasked (\io-> io `onException` (h io)) c

-- increments counter, finds stream segment of corresponding cell (updating the
-- stream head pointer as needed), and returns the stream segment and relative
-- index of our cell.
moveToNextCell :: ChanEnd a -> IO (Int, Stream a)
{-# INLINE moveToNextCell #-}
moveToNextCell (ChanEnd segSource counter streamHead) = do
    -- NOTE [3]
    (StreamHead offset0 str0) <- readIORef streamHead
    -- fetch-and-add is a full barrier on x86; but we want to make sure GHC
    -- doesn't move the read above ahead of our incrCounter below, so:
    loadLoadBarrier  -- [*]
    ix <- incrCounter 1 counter
    let (segsAway, segIx) = assert ((ix - offset0) >= 0) $ 
                 divMod_sEGMENT_LENGTH $! (ix - offset0)
              -- (ix - offset0) `quotRem` sEGMENT_LENGTH
        {-# INLINE go #-}
        go 0 str = return str
        go !n (Stream _ next) =
            waitingAdvanceStream next segSource (nEW_SEGMENT_WAIT*segIx) -- NOTE [1]
              >>= go (n-1)
    str <- go segsAway str0
    when (segsAway > 0) $ do
        let !offsetN = 
              offset0 + (segsAway `unsafeShiftL` lOG_SEGMENT_LENGTH) --(segsAway*sEGMENT_LENGTH)
        -- [*] incrCounter is logically both an atomic read/write combined. We
        -- need to ensure the following write occurs after the "write" of the
        -- incrCounter, and we get that with causality from the "read" part
        writeIORef streamHead $ StreamHead offsetN str -- NOTE [2]
    return (segIx,str)
  -- [1] All readers or writers needing to work with a not-yet-created segment
  -- race to create it, but those past index 0 have progressively long waits; 20
  -- is chosen as 20 readIORefs should be more than enough time for writer/reader
  -- 0 to add the new segment (if it's not descheduled).
  --
  -- [2] advancing the stream head pointer on segIx == sEGMENT_LENGTH - 1 would
  -- be more correct, but this is simpler here. This may move the head pointer
  -- BACKWARDS if the thread was descheduled, but that's not a correctness
  -- issue.
  --
  -- [3] There is a theoretical race condition here: thread reads head and is
  -- descheduled, meanwhile other readers/writers increment counter one full
  -- lap; when we increment we think we've found our cell in what is actually a
  -- very old segment. However in this scenario all addressable memory will
  -- have been consumed just by the array pointers which haven't been able to
  -- be GC'd. So I don't think this is something to worry about.


-- thread-safely try to fill `nextSegRef` at the next offset with a new
-- segment, waiting some number of iterations (for other threads to handle it).
-- Returns nextSegRef's StreamSegment.
waitingAdvanceStream :: IORef (NextSegment a) -> SegSource a 
                     -> Int -> IO (Stream a)
waitingAdvanceStream nextSegRef segSource = go where
  go !wait = assert (wait >= 0) $ do
    tk <- readForCAS nextSegRef
    case peekTicket tk of
         NoSegment 
           | wait > 0 -> go (wait - 1)
             -- Create a potential next segment and try to insert it:
           | otherwise -> do 
               potentialStrNext <- Stream <$> segSource 
                                          <*> newIORef NoSegment
               (_,tkDone) <- casIORef nextSegRef tk (Next potentialStrNext)
               -- If that failed another thread succeeded (no false negatives)
               case peekTicket tkDone of
                 Next strNext -> return strNext
                 _ -> error "Impossible! This should only have been Next segment"
         Next strNext -> return strNext


-- copying a template array with cloneMutableArray is much faster than creating
-- a new one; in fact it seems we need this in order to scale, since as cores
-- increase we don't have enough "runway" and can't allocate fast enough:
type SegSource a = IO (StreamSegment a)

newSegmentSource :: IO (SegSource a)
newSegmentSource = do
    -- NOTE: evaluate Empty seems to be required here in order to not raise
    -- "Stored Empty Ticket went stale!"  exception when in GHCi.
    arr <- evaluate Empty >>= P.newArray sEGMENT_LENGTH
    return (P.cloneMutableArray arr 0 sEGMENT_LENGTH)

-- ----------
-- CELLS AND GC:
--
--   Each cell in a segment is assigned at most one reader and one writer
--
--   When all readers disappear and writers continue we'll have at most one
--   segment-worth of garbage that can't be collected at a time; when writers
--   advance the head segment pointer, the previous may be GC'd.
--
--   Readers blocked indefinitely should eventually raise a
--   BlockedIndefinitelyOnMVar.
-- ----------
