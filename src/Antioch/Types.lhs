> module Antioch.Types where

> import Antioch.DateTime
> import Data.Function (on)
> import Data.Ix

> type Frequency = Float
> type Minutes   = Int
> type Score     = Float
> type Radians   = Float

> quarter = 15 :: Minutes

> data Receiver = NoiseSource
>               | Rcvr_RRI
>               | Rcvr_342
>               | Rcvr_450
>               | Rcvr_600
>               | Rcvr_800
>               | Rcvr_1070
>               | Rcvr1_2
>               | Rcvr2_3
>               | Rcvr4_6
>               | Rcvr8_10
>               | Rcvr12_18
>               | Rcvr18_22
>               | Rcvr22_26
>               | Rcvr26_40
>               | Rcvr40_52
>               | Rcvr_PAR
>               | Zpectrometer
>               | Holography
>               deriving (Eq, Show)

> data Grade = GradeA | GradeB | GradeC deriving (Eq, Show, Read)
> data Band = L | S | C | X | U | K | A | Q | W
>           deriving (Bounded, Enum, Eq, Ix, Ord, Read, Show)

TBF: Initially, Open, Fixed, and Windowed all share the same contents.
Ideally, we need to evolve these as we go and add new items and remove
useless items.

> data Session = Open {
>     sId         :: Int
>   , sName       :: String
>   , project     :: Project
>   , periods     :: [Period]
>   , totalTime   :: Minutes
>   , totalUsed   :: Minutes
>   , minDuration :: Minutes
>   , maxDuration :: Minutes
>   , timeBetween :: Minutes
>   , frequency   :: Float
>   , ra          :: Radians
>   , dec         :: Radians
>   , backup      :: Bool
>   , receivers   :: [Receiver]
>   , enabled     :: Bool
>   , authorized  :: Bool
>   , grade       :: Grade
>   , band        :: Band
>   }
>              | Fixed {
>     sId         :: Int
>   , sName       :: String
>   , project     :: Project
>   , period      :: Period
>   , totalTime   :: Minutes
>   , totalUsed   :: Minutes
>   , minDuration :: Minutes
>   , maxDuration :: Minutes
>   , timeBetween :: Minutes
>   , frequency   :: Float
>   , ra          :: Radians
>   , dec         :: Radians
>   , backup      :: Bool
>   , receivers   :: [Receiver]
>   , enabled     :: Bool
>   , authorized  :: Bool
>   , grade       :: Grade
>   , band        :: Band
>   }
>              | Windowed {
>     sId         :: Int
>   , sName       :: String
>   , project     :: Project
>   , periods     :: [Period]
>   , totalTime   :: !Minutes
>   , totalUsed   :: !Minutes
>   , minDuration :: !Minutes
>   , maxDuration :: !Minutes
>   , timeBetween :: !Minutes
>   , frequency   :: !Float
>   , ra          :: !Radians
>   , dec         :: !Radians
>   , backup      :: !Bool
>   , receivers   :: [Receiver]
>   , enabled     :: !Bool
>   , authorized  :: !Bool
>   , grade       :: !Grade
>   , band        :: !Band
>   } deriving (Show)

> instance Eq Session where
>     (==) = (==) `on` sId

> instance Ord Session where
>     compare = compare `on` sId

Need to calculate a windowed session's opportunities from its observation details.

> opportunities s@(Windowed { }) = []
> opportunities _                = []

Tying the knot.

> makeSession      :: Session -> [Period] -> Session
> makeSession s ps = s'
>   where
>     s' = s { totalUsed = t, periods = map (\p -> p { session = s' }) ps }
>     t  = sum . map duration $ ps

> updateSession      :: Session -> [Period] -> Session
> updateSession s ps = makeSession s $ periods s ++ ps

> data Project = Project {
>     pId       :: !Int
>   , pName     :: !String
>   , semester  :: !String
>   , sessions  :: [Session]
>   , thesis    :: !Bool
>   , timeLeft  :: !Minutes
>   , timeTotal :: !Minutes
>   } deriving Eq

> makeProject :: Project -> [Session] -> Project
> makeProject p ss = p'
>   where
>     p' = p { timeTotal = t, timeLeft = t, sessions = map (\s -> s { project = p' }) ss }
>     t  = sum . map totalTime $ ss

> instance Show Project where
>     show p = "Project: " ++ pName p ++ ", " ++ semester p ++ " Time: ("++ (show . timeTotal $ p) ++ ", " ++ (show . timeLeft $ p) ++ ") Sessions: " ++ show [ totalTime s | s <- sessions p] ++ ", " ++  show [ totalUsed s | s <- sessions p]

> data Period  = Period  {
>     session   :: Session
>   , startTime :: DateTime
>   , duration  :: Minutes
>   , pScore    :: Score  -- Average forecasted score
>   } 

> instance Show Period where
>     show p = "Period: " ++ printName p ++ " at " ++ toSqlString (startTime p) ++ " for " ++ show (duration p) ++ " with " ++ show (pScore p)
>       where 
>         n = sName . session $ p
>         printName p = if n == "" then show . sId . session $ p else n

> instance Ord Period where
>     (<) = (<) `on` startTime

TBF: Until scoring settles down, we want an equality operator for periods that
ignores their numerical scores.

> instance Eq Period where
>     (==) = periodsEqual

> periodsEqual :: Period -> Period -> Bool
> periodsEqual p1 p2 = eqStarts p1 p2 && eqDurs p1 p2 && eqIds p1 p2
>   where
>     eqStarts p1 p2 = startTime p1 == startTime p2
>     eqDurs   p1 p2 =  duration p1 == duration p2
>     eqIds    p1 p2 =   session p1 == session p2 


> defaultSession = Open {
>     sId         = 0
>   , sName       = ""
>   , project     = defaultProject 
>   , periods     = [defaultPeriod]
>   , totalTime   = 0
>   , totalUsed   = 0
>   , minDuration = 0
>   , maxDuration = 0
>   , timeBetween = 0
>   , frequency   = 0.0
>   , ra          = 0.0
>   , dec         = 0.0
>   , backup      = False
>   , receivers   = [Rcvr12_18]
>   , enabled     = False
>   , authorized  = False
>   , grade       = GradeA
>   , band        = L
>   }

> defaultOpen = Open {
>     sId         = 0
>   , sName       = ""
>   , project     = defaultProject 
>   , periods     = [defaultPeriod]
>   , totalTime   = 0
>   , totalUsed   = 0
>   , minDuration = 0
>   , maxDuration = 0
>   , timeBetween = 0
>   , frequency   = 0.0
>   , ra          = 0.0
>   , dec         = 0.0
>   , backup      = False
>   , receivers   = [Rcvr12_18]
>   , enabled     = False
>   , authorized  = False
>   , grade       = GradeA
>   , band        = L
>   }

> defaultFixed = Fixed {
>     sId         = 0
>   , sName       = ""
>   , project     = defaultProject 
>   , period      = defaultPeriod
>   , totalTime   = 0
>   , totalUsed   = 0
>   , minDuration = 0
>   , maxDuration = 0
>   , timeBetween = 0
>   , frequency   = 0.0
>   , ra          = 0.0
>   , dec         = 0.0
>   , backup      = False
>   , receivers   = [Rcvr12_18]
>   , enabled     = False
>   , authorized  = False
>   , grade       = GradeA
>   , band        = L
>   }

> defaultWindowed = Windowed {
>     sId         = 0
>   , sName       = ""
>   , project     = defaultProject 
>   , periods     = [defaultPeriod]
>   , totalTime   = 0
>   , totalUsed   = 0
>   , minDuration = 0
>   , maxDuration = 0
>   , timeBetween = 0
>   , frequency   = 0.0
>   , ra          = 0.0
>   , dec         = 0.0
>   , backup      = False
>   , receivers   = [Rcvr12_18]
>   , enabled     = False
>   , authorized  = False
>   , grade       = GradeA
>   , band        = L
>   }

> defaultOpen = Open {
>     sId         = 0
>   , sName       = ""
>   , project     = defaultProject 
>   , periods     = [defaultPeriod]
>   , totalTime   = 0
>   , totalUsed   = 0
>   , minDuration = 0
>   , maxDuration = 0
>   , timeBetween = 0
>   , frequency   = 0.0
>   , ra          = 0.0
>   , dec         = 0.0
>   , backup      = False
>   , receivers   = [Rcvr12_18]
>   , enabled     = False
>   , authorized  = False
>   , grade       = GradeA
>   , band        = L
>   }

> defaultFixed = Fixed {
>     sId         = 0
>   , sName       = ""
>   , project     = defaultProject 
>   , periods     = [defaultPeriod]
>   , totalTime   = 0
>   , totalUsed   = 0
>   , minDuration = 0
>   , maxDuration = 0
>   , timeBetween = 0
>   , frequency   = 0.0
>   , ra          = 0.0
>   , dec         = 0.0
>   , backup      = False
>   , receivers   = [Rcvr12_18]
>   , enabled     = False
>   , authorized  = False
>   , grade       = GradeA
>   , band        = L
>   }

> defaultWindowed = Windowed {
>     sId         = 0
>   , sName       = ""
>   , project     = defaultProject 
>   , periods     = [defaultPeriod]
>   , totalTime   = 0
>   , totalUsed   = 0
>   , minDuration = 0
>   , maxDuration = 0
>   , timeBetween = 0
>   , frequency   = 0.0
>   , ra          = 0.0
>   , dec         = 0.0
>   , backup      = False
>   , receivers   = [Rcvr12_18]
>   , enabled     = False
>   , authorized  = False
>   , grade       = GradeA
>   , band        = L
>   }

> defaultProject = Project {
>     pId       = 0
>   , pName     = ""
>   , semester  = ""
>   , sessions  = [defaultSession]
>   , thesis    = False
>   , timeLeft  = 0
>   , timeTotal = 0
>   }

> defaultPeriod = Period {
>     session   = defaultSession
>   , startTime = fromGregorian' 2008 1 1
>   , duration  = 0
>   , pScore    = 0.0
>   }
