> module Antioch.Generators where

> import Antioch.Types
> import Antioch.SLALib (slaGaleq)
> import Antioch.Utilities
> import Antioch.DateTime
> import Data.Char
> import Test.QuickCheck hiding (frequency)
> import qualified Test.QuickCheck as T

> instance Arbitrary Project where
>     arbitrary       = genProject
>     coarbitrary _ b = b

> instance Arbitrary Session where
>     arbitrary       = genSession
>     coarbitrary _ b = b

> instance Arbitrary Period where
>     arbitrary       = genPeriod
>     coarbitrary _ b = b

Generate a random project name: 'A' .. 'Z'

> genProjectName :: Gen Char 
> genProjectName = elements (map chr [65 .. 90])

TBF: Currently, the idea of semester is very limited.

> genSemesterName :: Gen String
> genSemesterName = elements ["07C", "08A", "08B", "08C"]

> genThesis :: Gen Bool
> genThesis = choose (False, True) -- T.frequency [(20, True), (80, False)]

TBF: how to line to Sessions that have already been generated?  and then use
those to calculate timeLeft and timeTotal?

> genProject :: Gen Project
> genProject = do
>     name     <- genProjectName
>     semester <- genSemesterName
>     thesis   <- genThesis
>     return $ defaultProject {
>           pName = str name
>         , semester = semester
>         , thesis = thesis
>         }

Now lets make sure we are properly generating Projects: test each attribute
at a time:

> prop_pName p = "A" <= pName p && pName p <= "Z"
> prop_semester p = any (==(semester p)) ["07C", "08A", "08B", "08C"]
> prop_thesis p = thesis p == True || thesis p == False

choose LST range and declination
s - single sources or few sources in one area of the sky
    g - galactic plane (some near GC)
    e - extra galactic
a - all sky or a large region of the sky

> skyType = elements "geegeegeeaaa"  -- sssa, s <- gee

> genRaDec 'g' = T.frequency [(20, galacticCenter), (80, galactic)]
>   where
>     galacticCenter = do
>         dec <- choose (-27.0, -29.0)
>         return (deg2rad 18.0, dec)
>     galactic = do
>         longitude <- choose (0.0, 250.0)
>         let (rar, decr) = slaGaleq (deg2rad longitude) 0.0
>         return (rar, rad2deg decr)
> genRaDec _   = do
>     ra  <- choose (0.0, 23.999)
>     dec <- fmap (rad2deg . asin) . choose $ (sin . deg2rad $ -35.0, sin . deg2rad $ 90.0)
>     return (hrs2rad ra, dec)

TBF: how to link these to generated Projects?

> genSession :: Gen Session
> genSession = do
>     p <- genProject
>     t <- genSemester
>     b <- genBand t 
>     f <- genFreq b
>     s <- skyType
>     (ra, dec)  <- genRaDec s
>     totalHours <- choose (2, 30)
>     minD       <- choose (2, 4)
>     maxD       <- choose (6, 8)
>     return $ defaultSession {
>                  project        = p
>                , band           = b
>                , frequency      = f
>                , ra             = ra
>                , dec            = dec
>                , minDuration    = minD
>                , maxDuration    = maxD
>                , totalTime      = totalHours
>                }

Done: quickCheck prop_Ra passes

> prop_Ra s = 0.0 <= ra s && ra s <= 2 * pi

TBF: this doesn't pass because Dec should be in rads

> prop_Dec s = (-pi) / 2 <= dec s && dec s <= pi / 2

TBF: thing is, this is in degrees, and it doesn't pass either!

> prop_DecDegree s = (-180) <= dec s && dec s <= 180 

TBF: start on 15 min. boundraies in a given time range. But how to make them
mutually exclusive?

> genStartTime :: Gen DateTime
> genStartTime = elements [fromGregorian' 2008 1 1, fromGregorian' 2008 1 2]

Durations for Periods come in 15 minute intervals, and probably aren't smaller
then an hour.  TBD: use T.frequency

> genDuration :: Gen Minutes
> genDuration = do
>     quarters <- choose (1*4, 10*4)
>     return $ quarters * 15

TBD:

> genScore :: Gen Score
> genScore = choose (0, 10)

> genPeriod :: Gen Period
> genPeriod = do
>      session   <- genSession  
>      startTime <- genStartTime
>      duration  <- genDuration
>      score     <- genScore
>      return $ Period {
>          session   = session
>        , startTime = startTime
>        , duration  = duration
>        , score     = score
>        }

Make sure Durations are made of 15-minute intervals

> prop_duration p = (duration p) `mod` 15 == 0

> type Semester = Int
  
> genSemester :: Gen Semester
> genSemester = fmap (read . str) . elements $ "0111122223333"

> prop_Semester = forAll genSemester $ \s -> s `elem` [0..3]

> str :: a -> [a]
> str = (: [])


choose observing band distribution
average up to trimester 7C

Band  Hours  Percent  Year  alloc
L     700    46.0%    27.6  26
S     130     8.6%     5.2   4
C     110     7.2%     4.3   5
X     120     7.9%     4.7   4
U      90     5.9%     3.5   3
K     230    15.1%     9.1   6
A      60     3.9%     2.3   6
Q      80     5.3%     3.2   6

> genBand     :: Int -> Gen Band
> genBand sem = fmap (read . str) . elements $ bands !! sem
>   where
>     bands = [ "KKQQAAXUCCSLLLLLLLLL"  -- 0 => backup
>             , "KKKQQQAXUCCSSLLLLLLL"  -- 1
>             , "KQQAXUCSLLLLLLLLLLLL"  -- 2
>             , "KKQQAAAXXUCCSLLLLLLL"  -- 3
>             ]

Assume we are observing the water line 40% of the time.

> genFreq   :: Band -> Gen Float
> genFreq K = T.frequency [(40, return 22.2), (60, choose (18.0, 26.0))]
> genFreq L = return 2.0
> genFreq S = choose ( 2.0,  3.95)
> genFreq C = choose ( 3.95, 5.85)
> genFreq X = choose ( 8.0, 10.0)
> genFreq U = choose (12.0, 15.4)
> genFreq A = choose (26.0, 40.0)
> genFreq Q = choose (40.0, 50.0)
