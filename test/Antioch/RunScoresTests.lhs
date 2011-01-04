
> module Antioch.RunScoresTests where

> import Antioch.DateTime
> import Antioch.Score
> import Antioch.Types
> import Antioch.Weather      (Weather, getWeatherTest, minTSysPrime)
> import Antioch.Utilities
> import Antioch.PProjects
> import Antioch.Receiver
> import Antioch.ReceiverTemperatures
> import Antioch.RunScores

> import Test.HUnit
> import Data.List
> import Data.Maybe
> import Control.Monad.Trans  (lift, liftIO)

> tests = TestList [ 
>     test_runScorePeriods
>   , test_runScoreSession
>   , test_runFactors
>     ]

> test_runScorePeriods = TestCase $ do
>   scores <- runScorePeriods pids pTestProjects True
>   assertEqual "test_runScorePeriods_1" exp scores
>   scores <- runScorePeriods [450] projs True
>   assertEqual "test_runScorePeriods_2" exp2 scores
>     where
>   -- try the periods in PProjects wich mostly score zero
>   pids = [100, 101, 200, 201] -- from PProjects.lhs
>   scores' = [0.0, 0.0, 2.126854, 0.0]::[Score]
>   exp = zip pids scores'
>   -- now create a period that should score non-zero
>   s = defaultSession { receivers = [[Rcvr1_2]] 
>                      , frequency = 1.1
>                      , dec = 1.5 -- always up
>                      }
>   p = defaultPeriod { session = s
>                     , startTime = fromGregorian 2006 2 1 0 30 0
>                     , duration = 60
>                     , peId = 450
>                     }
>   s' = makeSession s [] [p]
>   proj = defaultProject
>   projs = [makeProject proj 100 100 [s']]
>   exp2 = [(450, 0.37846184)]


> test_runScoreSession = TestCase $ do
>   score <- runScoreSession sessId startDt 60 projs True
>   assertEqual "test_runScoreSession_1" exp score
>   --score <- runScoreSession id dt dur pTestProjects True
>   --assertEqual "test_runScoreSession_1" exp score
>     where
>   --id = 13
>   --dt = fromGregorian 2006 9 23 12 0 0
>   --dur = 30
>   -- setup session like ScoreTests.test_scorePeriod
>   scores = [1.6321898,1.6325561,1.6327252,1.632888]
>   exp = ((sum $ tail scores) / 4.0)::Score 
>   startDt = fromGregorian 2006 2 1 0 30 0
>   s = head pSessions
>   sessId = sId s
>   p = defaultPeriod { session = s
>                       , startTime = startDt
>                       , duration = 60
>                       , pForecast = startDt
>                       }
>   s' = makeSession s [] [p]
>   proj = defaultProject
>   projs = [makeProject proj 0 0 pSessions]

> test_runFactors = TestCase $ do
>   let dt = fromGregorian 2006 9 2 14 30 0
>   let s' = findPSessionByName "CV"
>   let s = s' { sId = 555 }
>   let dur = 15::Minutes
>   let proj = defaultProject
>   let projs = [makeProject proj 1000 1000 ([s] ++ pSessions)]
>   -- Here we try to get the same results as ScoreTests.test_scoreFactors & test_scoreElements
>   -- and we can, except for pressures and some project info
>   (sess, factors) <- runFactors 555 dt dur projs True
>   assertEqual "test_runFactors 0" 1 (length factors)
>   assertEqual "test_runFactors 1" 32 (length . head $ factors)
>   assertEqual "test_runFactors 2" sess s
>   mapM_ (assertFactor factors) exp 
>       where
>     lookup' factors name = fromJust . fromJust . lookup name . head $ factors
>     assertFactor factors (key, value) = assertEqual ("test_scoreFactors " ++ key) value (lookup' factors key)
>     exp = [("stringency",1.0954108)
>           ,("atmosphericEfficiency",0.9439829)
>           ,("surfaceObservingEfficiency",0.9982148)
>           ,("trackingEfficiency",0.99917835)
>           -- Pressures differ due to diff in session pool
>           --,("rightAscensionPressure",1.0) 
>           --,("frequencyPressure",1.9724026)
>           ,("observingEfficiencyLimit",1.0)
>           ,("hourAngleLimit",1.0)
>           ,("zenithAngleLimit",1.0)
>           ,("trackingErrorLimit",1.0)
>           ,("atmosphericStabilityLimit",1.0)
>           ,("scienceGrade",1.0)
>           ,("thesisProject",1.0)
>           -- this tests' project isn't identical 
>           --,("projectCompletion",1.0024)
>           ,("observerOnSite",1.0)
>           ,("receiver",1.0)
>           ,("needsLowRFI",1.0)
>           ,("lstExcepted",1.0)
>           ,("observerAvailable",1.0)
>           ,("projectBlackout",1.0)
>           ,("inWindows",1.0)
>           -- scoreElements
>           , ("opacity", 8.786574e-3)
>           , ("elevation", 36.60029)
>           , ("sysNoiseTemp", 23.294113)
>           ]


Utilities:

> pSessions = zipWith6 genPSess tots useds ras bands grades ids
>   where tots   = [12*60, 18*60, 10*60, 20*60]
>         useds  = [ 2*60,  8*60,  5*60, 12*60]
>         ras    = [  5.4,  10.1,   4.9,  18.1]
>         bands  = [    L,     C,     X,     L]
>         grades = [4.0, 4.0, 4.0, 4.0]
>         ids    = [340, 341, 342, 343]
>         genPSess t u ra b g i = defaultSession {
>             sId = i
>           , sAllottedS = t
>           , sAllottedT = t
>           , periods = [defaultPeriod {duration = u
>                                     , pState = Scheduled
>                                     , pDuration = u}]
>           , ra = hrs2rad ra
>           , band = b
>           , grade = g
>           , receivers = [[Rcvr1_2]] 
>         }
