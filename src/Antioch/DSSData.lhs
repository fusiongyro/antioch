Copyright (C) 2011 Associated Universities, Inc. Washington DC, USA.

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.

Correspondence concerning GBT software should be addressed as follows:
      GBT Operations
      National Radio Astronomy Observatory
      P. O. Box 2
      Green Bank, WV 24944-0002 USA

> module Antioch.DSSData where

> import Antioch.DateTime
> import Antioch.DBUtilities
> import Antioch.Types
> import Antioch.Score
> import Antioch.Settings                (dssDataDB, dssHost, databasePort)
> import Antioch.SLALib (slaGaleq)
> import Antioch.DSSReversion            (putPeriodReversion)
> import Antioch.Utilities
> import Control.Monad.Trans             (liftIO)
> import Data.List                       (sort, nub, find)
> import Data.Char                       (toUpper)
> import Data.Maybe                      (fromJust, isNothing)
> import Database.HDBC
> import Database.HDBC.PostgreSQL


> connect :: IO Connection
> connect = handleSqlError $ connectPostgreSQL cnnStr 
>   where
>     cnnStr = "host=" ++ dssHost ++ " dbname=" ++ dssDataDB ++ " port=" ++ databasePort ++ " user=dss"

> getProjects :: IO [Project]
> getProjects = do
>     cnn <- connect
>     projs' <- fetchProjectData cnn
>     projs <- mapM (populateProject cnn) projs' 
>     return projs

> fetchProjectData :: Connection -> IO [Project]
> fetchProjectData cnn = handleSqlError $ do
>   result <- quickQuery' cnn query []
>   return $ toProjectDataList result
>     where
>       query = "SELECT p.id, p.pcode, s.semester, p.thesis, p.complete \
>              \ FROM semesters AS s, projects AS p \
>              \ WHERE s.id = p.semester_id ORDER BY p.pcode"
>       toProjectDataList = map toProjectData
>       toProjectData (id:pcode:semester:thesis:comp:[]) = 
>         defaultProject {
>             pId = fromSql id 
>           , pName = fromSql pcode 
>           , semester = fromSql semester  
>           , thesis = fromSql thesis 
>           , pClosed = fromSql comp
>         }

> populateProject :: Connection -> Project -> IO Project
> populateProject cnn project = do
>     sessions <- getSessions (pId project) cnn
>     sessions' <- mapM (populateSession cnn) sessions
>     -- project times
>     allotments <- getProjectAllotments (pId project) cnn
>     let project' = setProjectAllotments project allotments
>     -- project observers (will include observer blackouts!)
>     observers <- getProjectObservers (pId project) cnn
>     let project'' = setProjectObservers project' observers
>     -- project required friends (includes their blackouts too)
>     reqFriends <- getProjectRequiredFriends (pId project) cnn
>     let project''' = project'' { requiredFriends = reqFriends }
>     -- project blackouts
>     blackouts <- getProjectBlackouts cnn (pId project)
>     let project'''' = project''' { pBlackouts = blackouts }
>     return $ makeProject project'''' (pAllottedT project'''') (pAllottedS project'''') sessions'

The scheduling algorithm does not need to know all the details about the observers
on a project - it only needs a few key facts, which are defined in the Observer
data structure.  These facts come from two sources:
   1. DSS Database:
      * observer sanctioned flag 
      * observer black out dates
   2. BOS web service:
      * observer on site dates (GB reservation date)

Note: Beware original_id, pst_id,  and contact_instructions
in the User table can be null.

> getProjectObservers :: Int -> Connection -> IO [Observer]
> getProjectObservers projId cnn = handleSqlError $ do
>     -- 0. Get basic info on observers: pst id, sanctioned
>     observers' <- getObservers projId cnn
>     -- 1. Use these to lookup the needed info from the BOS web service.
>     -- 1. Use these to lookup the needed info from the DSS database
>     observers <- mapM (populateObserver cnn) observers'
>     -- return obs
>     return observers 

> setProjectObservers :: Project -> [Observer] -> Project
> setProjectObservers proj obs = proj { observers = obs }

Sets the basic Observer Data Structure info

> getObservers :: Int -> Connection -> IO [Observer]
> getObservers projId cnn = do
>   result <- quickQuery' cnn query xs 
>   return $ toObserverList result 
>     where
>       xs = [toSql projId]
>       query = "SELECT u.id, u.first_name, u.last_name, u.sanctioned, u.pst_id \
>              \ FROM investigators AS inv, users AS u \
>              \ WHERE u.id = inv.user_id AND inv.observer AND inv.project_id = ?"
>       toObserverList = map toObserver
>       toObserver (id:first:last:sanc:pid:[]) = 
>         defaultObserver 
>           { oId = fromSql id
>           , firstName = fromSql first
>           , lastName = fromSql last
>           , sanctioned = fromSql sanc
>           , pstId = fromSqlInt pid }

Takes Observers with basic info and gets the extras: blackouts, reservations

> populateObserver :: Connection -> Observer -> IO Observer
> populateObserver cnn observer = do
>     bs <- getObserverBlackouts cnn observer
>     res <- getObserverReservations cnn observer
>     return observer { blackouts = bs, reservations = res }

Note that start_date and end_date refer respectively to the check-in
and check-out dates, e.g., a person with a start_date of 03/13/2011
and an end_date of 03/15/2011 would spend two nights in Green Bank,
the nights of 03/13/2011 and 03/14/2011. Therefore the time range
would be 03/13/2011 00:00 <= on site < 3/16/2011 00:00.

> getObserverBlackouts :: Connection -> Observer -> IO [DateRange]
> getObserverBlackouts cnn obs = do
>   result <- quickQuery' cnn query xs
>   return $ toBlackoutDatesList result
>     where
>       xs = [toSql . oId $ obs]
>       query = "SELECT b.start_date, b.end_date, r.repeat, b.until \
>              \ FROM blackouts AS b, repeats AS r \
>              \ WHERE r.id = b.repeat_id AND user_id = ?"

> toBlackoutDatesList = concatMap toBlackoutDates
>     where
>       toBlackoutDates (s:e:r:u:[]) = toDateRangesFromInfo (sqlToBlackoutStart s) (sqlToBlackoutEnd e) (fromSql r) (sqlToBlackoutEnd u)
>
>       -- These two methods define the start and end of blackouts in case of NULLs in the DB.
>       sqlToBlackoutStart SqlNull = blackoutsStart
>       sqlToBlackoutStart dt      = sqlToDateTime dt 
>       sqlToBlackoutEnd SqlNull = blackoutsEnd
>       sqlToBlackoutEnd dt      = sqlToDateTime dt 
>       -- When converting repeats to a list of dates, when do these dates start and end?
>       blackoutsStart = fromGregorian 2009 9 1 0 0 0
>       blackoutsEnd   = fromGregorian 2010 2 1 0 0 0

Required Friends need to be available for observing, they are
subtly different then our list of observers, though use the same
data type.

> getProjectRequiredFriends :: Int -> Connection -> IO [Observer]
> getProjectRequiredFriends projId cnn = handleSqlError $ do
>     friends' <- getRequiredFriends projId cnn
>     friends <- mapM (populateObserver cnn) friends'
>     return friends 

> getRequiredFriends :: Int -> Connection -> IO [Observer]
> getRequiredFriends projId cnn = do
>   result <- quickQuery' cnn query xs 
>   return $ toObserverList result 
>     where
>       xs = [toSql projId]
>       query = "SELECT u.id, u.first_name, u.last_name, u.sanctioned, u.pst_id \
>              \ FROM friends AS f, users AS u \
>              \ WHERE u.id = f.user_id AND f.required AND f.project_id = ?"
>       toObserverList = map toObserver
>       toObserver (id:first:last:sanc:pid:[]) = 
>         defaultObserver 
>           { oId = fromSql id
>           , firstName = fromSql first
>           , lastName = fromSql last
>           , sanctioned = fromSql sanc
>           , pstId = fromSqlInt pid }

For a given project Id, if that project allows blackouts, reads in these
blackouts just like blackouts are read in for an observer.

> getProjectBlackouts :: Connection -> Int -> IO [DateRange]
> getProjectBlackouts cnn projId = do
>   b <- usesBlackouts cnn projId
>   if b then getProjectBlackouts' cnn projId else return $ []

Reads in blackouts for a given project.

> getProjectBlackouts' :: Connection -> Int -> IO [DateRange]
> getProjectBlackouts' cnn projId = do
>   result <- quickQuery' cnn query xs
>   return $ toBlackoutDatesList result
>     where
>       xs = [toSql projId]
>       query = "SELECT b.start_date, b.end_date, r.repeat, b.until \
>              \ FROM blackouts AS b, repeats AS r \
>              \ WHERE r.id = b.repeat_id AND project_id = ?"

Does the given project (by Id) allow blackouts?  Check the flag.

> usesBlackouts :: Connection -> Int -> IO Bool
> usesBlackouts cnn projId = do
>   result <- quickQuery' cnn query [toSql projId]
>   return $ fromSql . head . head $ result
>     where
>       query = "SELECT blackouts FROM projects WHERE id = ?"

Convert from a description of the blackout to the actual dates

> toDateRangesFromInfo :: DateTime -> DateTime -> String -> DateTime -> [DateRange]
> toDateRangesFromInfo start end repeat until | repeat == "Once" = [(start, end)]
>                                             | repeat == "Weekly" = toWeeklyDateRanges start end until
>                                             | repeat == "Monthly" = toMonthlyDateRanges start end until
>                                             | otherwise = [(start, end)] -- WTF

> toWeeklyDateRanges :: DateTime -> DateTime -> DateTime -> [DateRange]
> toWeeklyDateRanges start end until | start > until = []
>                                    | otherwise = (start, end):(toWeeklyDateRanges (nextWeek start) (nextWeek end) until)
>   where
>     nextWeek dt = addMinutes weekMins dt
>     weekMins = 7 * 24 * 60

> toMonthlyDateRanges :: DateTime -> DateTime -> DateTime -> [DateRange]
> toMonthlyDateRanges start end until | start > until = []
>                                     | otherwise = (start, end):(toMonthlyDateRanges (addMonth start) (addMonth end) until)

Note: We have had trouble connecting to the BOS service from Haskell.  So, instead 
of investing more time into a dead language, we are simply reading these from an 
intermediate table in the DSS DB.

> getObserverReservations :: Connection -> Observer -> IO [DateRange]
> getObserverReservations cnn obs = do 
>   result <- quickQuery' cnn query xs
>   return $ toResDatesList result
>     where
>       xs = [toSql . oId $ obs]
>       query = "SELECT start_date, end_date FROM reservations WHERE user_id = ?"
>       toResDatesList = concatMap toResDates
>       toResDates (s:e:[]) = [(sqlToDateTime s, sqlToDateTime e)]

We must query for the allotments separately, because if a Project has alloted
time for more then one grade (ex: 100 A hrs, 20 B hrs), then that will be
two allotments, and querying w/ a join will duplicate the project.

> getProjectAllotments :: Int -> Connection -> IO [(Minutes, Minutes, Grade)]
> getProjectAllotments projId cnn = handleSqlError $ do 
>   result <- quickQuery' cnn query xs 
>   return $ toAllotmentList result 
>     where
>       query = "SELECT a.total_time, a.max_semester_time, a.grade \
>              \ FROM allotment AS a, projects AS p, projects_allotments AS pa \
>              \ WHERE p.id = pa.project_id AND a.id = pa.allotment_id AND p.id = ?"
>       xs = [toSql projId]
>       toAllotmentList = map toAllotment
>       toAllotment (ttime:mstime:grade:[]) = (fromSqlMinutes ttime, fromSqlMinutes mstime, fromSql grade)

We are ignoring grade and summing the different hours together to get the total time.

> setProjectAllotments :: Project -> [(Minutes, Minutes, Grade)] -> Project
> setProjectAllotments p [] = p
> setProjectAllotments p ((t,s,g):xs) =
>     setProjectAllotments (p {pAllottedT = (pAllottedT p) + t
>                            , pAllottedS = (pAllottedS p) + s} ) xs

Note: If a session is missing any of the tables in the below query, it won't
get picked up, since this is a default inner join query.  The database
health report should pickup sessions with incomplete information.  Here
we will ignore them since session like these should not be consider for
scheduling until they are properly defined.

> getSessions :: Int -> Connection -> IO [Session]
> getSessions projId cnn = handleSqlError $ do 
>   result <- quickQuery' cnn query xs 
>   let ss' = toSessionDataList result
>   ss <- mapM (updateRcvrs cnn) ss' 
>   return ss
>     where
>       query = "SELECT DISTINCT s.id, s.name, s.min_duration, s.max_duration, \
>                              \ s.time_between, s.frequency, a.total_time, \
>                              \ a.max_semester_time, a.grade, sy.name, t.horizontal, \
>                              \ t.vertical, st.enabled, st.authorized, \
>                              \ st.backup, st.complete, stype.type, \
>                              \ otype.type \
>                              \ FROM sessions AS s, allotment AS a, targets AS t, \
>                              \ status AS st, session_types AS stype, \
>                              \ observing_types AS otype, systems as sy\
>                              \ WHERE a.id = s.allotment_id AND \
>                              \ t.session_id = s.id AND s.status_id = st.id AND \
>                              \ s.session_type_id = stype.id AND \
>                              \ s.observing_type_id = otype.id AND t.system_id = sy.id AND \
>                              \ s.frequency IS NOT NULL AND \
>                              \ t.horizontal IS NOT NULL AND \
>                              \ t.vertical IS NOT NULL AND \
>                              \ s.project_id = ? order by s.id;"
>       xs = [toSql projId]
>       toSessionDataList = map toSessionData
>       toSessionData (id:name:mind:maxd:between:freq:ttime:stime:grade:sys:h:v:e:a:b:c:sty:oty:[]) = 
>         defaultSession {
>             sId = fromSql id 
>           , sName = fromSql name
>           , frequency   = fromSql freq
>           , minDuration = fromSqlMinutes' mind 3
>           , maxDuration = fromSqlMinutes' maxd 12
>           , timeBetween = fromSqlMinutes' between 0
>           , sAllottedT  = fromSqlMinutes ttime
>           , sAllottedS  = fromSqlMinutes stime
>           , ra = ra
>           , dec = dec
>           , grade = fromSql grade
>           , receivers = [] 
>           , periods = [] -- no history in Carl's DB
>           , enabled = fromSql e
>           , authorized = fromSql a
>           , backup = fromSql b
>           , band = deriveBand $ fromSql freq
>           , sClosed = fromSql c
>           , sType = toSessionType sty
>           , oType = toObservingType oty
>         }
>           where
>               horz = fromSql h
>               vert = fromSql v
>               (ra, dec) = 
>                   if (fromSql sys) == "Galactic" then (slaGaleq horz vert) else (horz, vert)

> getSessionFromPeriod :: Int -> Connection -> IO Session
> getSessionFromPeriod periodId cnn = handleSqlError $ do 
>   result <- quickQuery' cnn query xs 
>   let s' = toSessionData . head $ result
>   s <- updateRcvrs cnn s' 
>   return s
>     where
>       query = "SELECT s.id, s.name, s.min_duration, s.max_duration, s.time_between, \
>              \ s.frequency, a.total_time, a.max_semester_time, a.grade, sy.name, t.horizontal, \
>              \ t.vertical, st.enabled, st.authorized, st.backup, st.complete, type.type \
>              \ FROM sessions AS s, allotment AS a, targets AS t, status AS st, \
>              \ session_types AS type, periods AS p, systems AS sy \
>              \ WHERE s.id = p.session_id AND \
>              \ a.id = s.allotment_id AND t.session_id = s.id AND t.system_id = sy.id \
>              \ AND s.status_id = st.id AND s.session_type_id = type.id \
>              \ AND s.frequency IS NOT NULL AND t.horizontal IS NOT NULL AND \
>              \ t.vertical IS NOT NULL AND p.id = ? order by s.id"
>       xs = [toSql periodId]
>       toSessionDataList = map toSessionData
>       toSessionData (id:name:mind:maxd:between:freq:ttime:stime:grade:sys:h:v:e:a:b:c:sty:[]) = 
>         defaultSession {
>             sId = fromSql id 
>           , sName = fromSql name
>           , frequency   = fromSql freq
>           , minDuration = fromSqlMinutes' mind 3
>           , maxDuration = fromSqlMinutes' maxd 12
>           , timeBetween = fromSqlMinutes' between 0
>           , sAllottedT  = fromSqlMinutes ttime 
>           , sAllottedS  = fromSqlMinutes stime 
>           , ra = ra
>           , dec = dec
>           , grade = fromSql grade
>           , receivers = []
>           , periods = [] -- Note:, no history in Carl's DB
>           , enabled = fromSql e
>           , authorized = fromSql a
>           , backup = fromSql b
>           , band = deriveBand $ fromSql freq
>           , sClosed = fromSql c
>           , sType = toSessionType sty
>         }
>           where
>               horz = fromSql h
>               vert = fromSql v
>               (ra, dec) = 
>                   if (fromSql sys) == "Galactic" then (slaGaleq horz vert) else (horz, vert)

> getSession :: Int -> Connection -> IO Session
> getSession sessionId cnn = handleSqlError $ do 
>   result <- quickQuery' cnn query xs 
>   let s' = toSessionData $ result !! 0
>   s <- updateRcvrs cnn s' 
>   return s
>     where
>       query = "SELECT s.id, s.name, s.min_duration, s.max_duration, s.time_between, \
>              \ s.frequency, a.total_time, a.max_semester_time, a.grade, sy.name, t.horizontal, \
>              \ t.vertical, st.enabled, st.authorized, st.backup, st.complete, type.type \
>              \ FROM sessions AS s, allotment AS a, targets AS t, status AS st, \
>              \ session_types AS type, systems As sy\
>              \ WHERE a.id = s.allotment_id AND t.session_id = s.id AND s.status_id = st.id AND \
>              \ s.session_type_id = type.id AND t.system_id = sy.id AND s.id = ? order by s.id"
>       xs = [toSql sessionId]
>       toSessionData (id:name:mind:maxd:between:freq:ttime:stime:grade:sys:h:v:e:a:b:c:sty:[]) = 
>         defaultSession {
>             sId = fromSql id 
>           , sName = fromSql name
>           , frequency   = fromSql freq
>           , minDuration = fromSqlMinutes' mind 3
>           , maxDuration = fromSqlMinutes' maxd 12
>           , timeBetween = fromSqlMinutes' between 0
>           , sAllottedT  = fromSqlMinutes ttime
>           , sAllottedS  = fromSqlMinutes stime
>           , ra = ra
>           , dec = dec
>           , grade = fromSql grade
>           , receivers = [] 
>           , periods = [] -- no history in Carl's DB
>           , enabled = fromSql e
>           , authorized = fromSql a
>           , backup = fromSql b
>           , band = deriveBand $ fromSql freq
>           , sClosed = fromSql c
>           , sType = toSessionType sty
>         }
>           where
>               horz = fromSql h
>               vert = fromSql v
>               (ra, dec) = 
>                   if (fromSql sys) == "Galactic" then (slaGaleq horz vert) else (horz, vert)

Since the Session data structure does not support Nothing, when we get NULLs
from the DB (Carl didn't give it to us), then we need some kind of default
value of the right type.

> fromSqlInt :: SqlValue -> Int
> fromSqlInt SqlNull = 0
> fromSqlInt x       = fromSql x

> fromSqlMinutes :: SqlValue -> Minutes
> fromSqlMinutes x               = sqlHrsToMinutes x

> fromSqlMinutes' :: SqlValue -> Minutes -> Minutes
> fromSqlMinutes' SqlNull def     = def
> fromSqlMinutes' x _             = sqlHrsToMinutes x

> sqlHrsToHrs' :: SqlValue -> Float
> sqlHrsToHrs' hrs = fromSql hrs

> hrsToMinutes :: Float -> Minutes
> hrsToMinutes hrs = floor $ 60.0 * hrs

> sqlHrsToMinutes :: SqlValue -> Minutes
> sqlHrsToMinutes hrs = hrsToMinutes . sqlHrsToHrs' $ hrs

> toSessionType :: SqlValue -> SessionType
> toSessionType val = read . toUpperFirst $ fromSql val
>   where
>     toUpperFirst x = [toUpper . head $ x] ++ tail x

> toObservingType :: SqlValue -> ObservingType
> toObservingType val = read . toUpperFirst $ fromSql val
>   where
>     toUpperFirst x = if x == "spectral line" then "SpectralLine" else [toUpper . head $ x] ++ tail x

Given a Session, find the Rcvrs for each Rcvr Group.
This is a separate func, and not part of the larger SQL in getSessions
in part because if there are *no* rcvrs, that larger SQL would not return
*any* result 
Note, start_date in Receiver_Schedule table can be null.

> updateRcvrs :: Connection -> Session -> IO Session
> updateRcvrs cnn s = do
>   rcvrGroups <- getRcvrGroups cnn s
>   cnfRcvrs <- mapM (getRcvrs cnn s) rcvrGroups
>   return $ s {receivers = cnfRcvrs}

> getRcvrGroups :: Connection -> Session -> IO [Int]
> getRcvrGroups cnn s = do
>   result <- quickQuery' cnn query xs 
>   return $ toRcvrGrpIds result
>   where
>     xs = [toSql . sId $ s]
>     query = "SELECT rg.id FROM receiver_groups AS rg WHERE rg.session_id = ?"
>     toRcvrGrpIds = map toRcvrGrpId 
>     toRcvrGrpId [x] = fromSql x

> getRcvrs :: Connection -> Session -> Int -> IO ReceiverGroup
> getRcvrs cnn s id = do
>   result <- quickQuery' cnn query xs 
>   return $ toRcvrList s result
>   where
>     xs = [toSql id]
>     query = "SELECT r.name \
>              \ FROM receivers as r, receiver_groups_receivers as rgr \
>              \ WHERE rgr.receiver_id = r.id AND rgr.receiver_group_id = ?"
>     toRcvrList s = map (toRcvr s)
>     toRcvr s [x] = toRcvrType s x

> toRcvrType :: Session -> SqlValue -> Receiver
> toRcvrType s val = read . fromSql $ val

Here, we gather additional information about a session: periods, windows,
observing parameters, etc.

> populateSession :: Connection -> Session -> IO Session
> populateSession cnn s = do
>     -- order here is important:
>     s' <- updateRcvrs cnn s
>     -- need to know what rcvrs are used when setting observing params
>     s'' <- setObservingParameters cnn s'
>     ps <- getPeriods cnn s''
>     ws <- getWindows cnn s''
>     es <- getElectives cnn s''
>     let s''' = s'' { electives = es }
>     return $ makeSession s''' ws ps

The following recursive patterns work for setting the observing params
that are one-to-one between the DB and the Session (ex: Night Time -> low rfi).  However,
we'll need to handle as a special case some params that we want to take from
the DB and collapse into simpler Session params (ex: LST ranges).

> setObservingParameters :: Connection -> Session -> IO Session
> setObservingParameters cnn s = do
>   result <- quickQuery' cnn query xs 
>   -- set the correct default value for the track error threshold first
>   let s' = s { trkErrThreshold = getThresholdDefault s }
>   let s'' = setObservingParameters' s' result
>   s''' <- setLSTExclusion cnn s''
>   return s'''
>     where
>       xs = [toSql . sId $ s]
>       query = "SELECT p.name, p.type, op.string_value, op.integer_value, op.float_value, \
>              \ op.boolean_value, op.datetime_value \
>              \ FROM observing_parameters AS op, parameters AS p \
>              \ WHERE p.id = op.parameter_id AND op.session_id = ?" 

> getThresholdDefault :: Session -> Float
> getThresholdDefault s = if usesFilledArray s then trkErrThresholdFilledArrays else trkErrThresholdSparseArrays

> setObservingParameters' :: Session -> [[SqlValue]] -> Session
> setObservingParameters' s sqlRows = foldl setObservingParameter s sqlRows 

For now, just set:
   * low rfi flag
   * transit flag
   * xi factor
   * elevation limit 
   * good atmospheric stability
   * guaranteed flag
   * source size
   * tracking error threshold
   * keyhole

> setObservingParameter :: Session -> [SqlValue] -> Session
> setObservingParameter s (pName:pType:pStr:pInt:pFlt:pBool:pDT)
>     | n == "Time Of Day"     = s { timeOfDay = toTimeOfDay pStr }
>     | n == "Transit"         = s { transit = toTransit pBool }
>     | n == "Min Eff TSys"    = s { xi = fromSql pFlt }    
>     | n == "El Limit"        = s { elLimit = toElLimit pFlt }    
>     | n == "Not Guaranteed"  = s { guaranteed = not . fromSql $ pBool }   
>     | n == "Source Size"     = s { sourceSize = fromSql pFlt }
>     | n == "Tr Err Limit"    = s { trkErrThreshold = fromSql pFlt }
>     | n == "Keyhole"         = s { keyhole = fromSql pBool }
>     | n == "Irradiance Threshold"        = s { irThreshold = fromSql pFlt }
>     | n == "Good Atmospheric Stability"  = s { goodAtmStb = fromSql $ pBool }   
>     | otherwise                          = s  
>   where
>     n = fromSql pName
>     toTransit t = toTransitType . toTransitBool $ t 

> toTimeOfDay :: SqlValue -> TimeOfDay
> toTimeOfDay v | v == SqlNull = AnyTimeOfDay
> toTimeOfDay v | otherwise    = read . fromSql $ v

> toElLimit :: SqlValue -> Maybe Float
> toElLimit v | v == SqlNull = Nothing
>             | otherwise    = Just $ deg2rad . fromSql $ v

> toTransitBool :: SqlValue -> Bool
> toTransitBool t = fromSql t

> toTransitType :: Bool -> TransitType
> toTransitType t = if t then Center else Optional

The DB's observing parameters may support both LST Exclusion flags *and*
LST Inclusion flags, where as our Session's only support the LST Exclusion
flags - so we'll have to collapse the DB's 2 types into our 1.

> setLSTExclusion :: Connection -> Session -> IO Session
> setLSTExclusion cnn s = do
>   result <- quickQuery' cnn query xs --Exclusion
>   let s' = addLSTExclusion' True s result
>   result <- quickQuery' cnn query' xs --Inclusion
>   return $ addLSTExclusion' False s' result
>     where
>       xs = [toSql . sId $ s]
>       query = "SELECT p.name, op.float_value \
>              \ FROM observing_parameters AS op, parameters AS p \
>              \ WHERE p.id = op.parameter_id AND p.name LIKE 'LST Exclude%' AND \
>              \ op.session_id = ? \
>              \ order by op.id" 
>       query' = "SELECT p.name, op.float_value \
>              \ FROM observing_parameters AS op, parameters AS p \
>              \ WHERE p.id = op.parameter_id AND p.name LIKE 'LST Include%' AND \
>              \ op.session_id = ? \
>              \ order by op.id" 

The 'ex' flag determines whether we are importing LST Exclusion ranges
or Inclusion ranges.

> addLSTExclusion' :: Bool -> Session -> [[SqlValue]] -> Session
> addLSTExclusion' _ s []         = s
> addLSTExclusion' ex s sqlValues = s { lstExclude = (lstExclude s) ++ lstRanges ex sqlValues }  

If we are importing the inclusion range, then reversing the endpoints makes
it an exclusion range.

> invertIn :: [Float] -> [Float] -> [(Float, Float)]
> invertIn [] []      = []
> invertIn [l] [h]    = if l == 0 then [(h, 24)] else [(0, l), (h, 24)]
> invertIn lows highs = filter (\x-> (not $ (0,0) == x) && (not $ (24.0, 24.0) == x)) $ splitIn $ 0:(zipConcat $ zip lows highs)++[24]

> zipConcat :: [(Float, Float)] -> [Float]
> zipConcat []     = []
> zipConcat (x:xs) = fst x : snd x : zipConcat xs

> splitIn :: [Float] -> [(Float, Float)]
> splitIn []        = []
> splitIn (x:y:xys) = (x, y) : splitIn xys

> lstRanges :: Bool -> [[SqlValue]] -> [(Float, Float)]
> lstRanges ex sqlValues = if ex then (zip lows highs) else (invertIn lows highs)
>   where
>     lows   = lstSplit ex "Low" sqlValues
>     highs  = lstSplit ex "Hi" sqlValues

> lstSplit :: Bool -> String -> [[SqlValue]] -> [Float]
> lstSplit ex dir sqlValues = map lstRange' $ filter (isLSTName n) sqlValues
>   where
>     n = if ex then "LST Exclude " ++ dir else "LST Include " ++ dir
>     lstRange' (pName:pValue:[]) = fromSql pValue

> isLSTName :: String -> [SqlValue] -> Bool
> isLSTName name (pName:pFloat:[]) = (fromSql pName) == name

> getElectives :: Connection -> Session -> IO [Electives]
> getElectives cnn s = do
>   result <- quickQuery' cnn query xs 
>   let elecs' = toElectiveList result
>   elecs <- mapM (getElectivePeriods cnn) elecs'
>   return elecs
>   where
>     xs = [toSql . sId $ s]
>     query = "SELECT id, complete FROM electives WHERE session_id = ?;"
>     toElectiveList = map toElective
>     toElective(id:comp:[]) =
>       Electives {eId = fromSql id
>                , eComplete = fromSql comp 
>                , ePeriodIds = [] -- for later
>                 }

> getElectivePeriods :: Connection -> Electives -> IO (Electives)
> getElectivePeriods cnn elec = do
>   result <- quickQuery' cnn query xs
>   let ids = toIdList result
>   return $ elec {ePeriodIds = ids}
>   where
>     xs = [toSql . eId $ elec]
>     query = "SELECT id FROM periods WHERE elective_id = ? ORDER BY start ASC;"
>     toIdList = map toId
>     toId(id:[]) = fromSql id

> getWindows :: Connection -> Session -> IO [Window]
> getWindows cnn s = do
>     dbWindows'' <- fetchWindows cnn s 
>     dbWindows' <- mapM (fetchWindowRanges cnn) dbWindows''
>     dbWindows <- mapM (adjustTotalTime cnn) $ filterCompleteWindows dbWindows'
>     return $ sort $ dbWindows

Remove any windows here that aren't setup properly.  Right now
we are only checking for existence of start and end times of window.

> filterCompleteWindows :: [Window] -> [Window]
> filterCompleteWindows ws = filter complete ws
>   where
>     complete w = (length . wRanges $ w) > 0

> adjustTotalTime :: Connection -> Window -> IO Window
> adjustTotalTime cnn w = do
>     tb <- getWindowTimeBilled cnn w
>     return w {wTotalTime = (wTotalTime w) - tb}

> fetchWindows :: Connection -> Session -> IO [Window]
> fetchWindows cnn s = do 
>   result <- quickQuery' cnn query xs 
>   return $ toWindowList result
>   where
>     xs = [toSql . sId $ s]
>     query = "SELECT id, default_period_id, complete, total_time FROM windows WHERE session_id = ?;"
>     toWindowList = map toWindow
>     toWindow(id:dpid:c:tt:[]) =
>       defaultWindow { wId        = fromSql id
>                     , wPeriodId  = sqlToDefaultPeriodId dpid
>                     , wComplete  = fromSql c
>                     , wTotalTime = fromSqlMinutes tt
>                     }

Non-Guaranteed Sessions don't have to have default periods for their
Windows.  So, really, wPeriodId should be of type Maybe Int.  

> sqlToDefaultPeriodId :: SqlValue -> Maybe Int
> sqlToDefaultPeriodId id | id == SqlNull = Nothing 
>                         | otherwise     = Just . fromSql $ id

A single Window can have mutliple date ranges associated with it.

> fetchWindowRanges :: Connection -> Window -> IO Window
> fetchWindowRanges cnn w = do 
>   result <- quickQuery' cnn query xs 
>   let ranges = toDateRangeList result
>   return w {wRanges = ranges}
>   where
>     xs = [toSql . wId $ w]
>     query = "SELECT start_date, duration FROM window_ranges WHERE window_id = ?"
>     toDateRangeList = map toDateRange
>     toDateRange (start:dur:[]) = (sqlToDate start, toEnd (sqlToDate start) (fromSql dur))
>     toEnd start days = addMinutes (days*24*60) start 

> getWindowTimeBilled :: Connection -> Window -> IO Minutes
> getWindowTimeBilled cnn w = do
>   result <- quickQuery' cnn query xs 
>   return . sum . toTotalTimeBilled $ result
>   where
>     xs = [toSql . wId $ w]
>     -- don't pick up deleted periods!
>     query = "SELECT state.abbreviation, pa.scheduled, pa.other_session_weather, \
>              \ pa.other_session_rfi, pa.other_session_other, pa.lost_time_weather, \
>              \ pa.lost_time_rfi, pa.lost_time_other, pa.not_billable \
>              \ FROM periods AS p, period_states AS state, periods_accounting AS pa \
>              \ WHERE state.id = p.state_id AND state.abbreviation != 'D' AND \
>              \ pa.id = p.accounting_id AND p.window_id = ?;"
>     toTotalTimeBilled = map toTimeBilled
>     toTimeBilled (state:sch:osw:osr:oso:ltw:ltr:lto:nb:[]) =
>        if (deriveState . fromSql $ state) == Pending
>        then 0::Minutes
>        else (fromSqlMinutes sch)  - (fromSqlMinutes osw) - (fromSqlMinutes osr) - (fromSqlMinutes oso) - (fromSqlMinutes ltw) -  (fromSqlMinutes ltr) - (fromSqlMinutes lto) - (fromSqlMinutes nb)

> getPeriods :: Connection -> Session -> IO [Period]
> getPeriods cnn s = do
>     dbPeriods <- fetchPeriods cnn s 
>     return $ sort $ dbPeriods

> fetchPeriods :: Connection -> Session -> IO [Period]
> fetchPeriods cnn s = do 
>   result <- quickQuery' cnn query xs 
>   return $ toPeriodList result
>   where
>     st = sType s
>     xs = [toSql . sId $ s]
>     -- don't pick up deleted periods!
>     query = "SELECT p.id, p.session_id, p.start, p.duration, p.score, state.abbreviation, \
>              \ p.forecast, p.backup, pa.scheduled, pa.other_session_weather, pa.other_session_rfi, \
>              \ pa.other_session_other, pa.lost_time_weather, pa.lost_time_rfi, pa.lost_time_other, \
>              \ pa.not_billable, p.moc \
>              \ FROM periods AS p, period_states AS state, periods_accounting AS pa \
>              \ WHERE state.id = p.state_id AND state.abbreviation != 'D' AND \
>              \ pa.id = p.accounting_id AND p.session_id = ?;"
>     toPeriodList = map toPeriod
>     toPeriod (id:sid:start:durHrs:score:state:forecast:backup:sch:osw:osr:oso:ltw:ltr:lto:nb:moc:[]) =
>       defaultPeriod { peId = fromSql id
>                     , startTime = sqlToDateTime start --fromSql start
>                     , duration = fromSqlMinutes durHrs
>                     , pScore = fromSql score
>                     , pState = deriveState . fromSql $ state
>                     , pForecast = sqlToDateTime forecast
>                     , pBackup = fromSql backup
>                     --, pDuration = fromSqlMinutes durHrs  -- db simulation
>                     -- time billed is complex for scheduled periods,
>                     -- but simple for pending (but not windowed).
>                     -- windows are an exception because they have 
>                     -- default periods in pending, whose time should not
>                     -- be counted.
>                     , pDuration = 
>                        if (deriveState . fromSql $ state) == Pending  && (st /= Windowed) && (st /= Elective)
>                        then fromSqlMinutes durHrs
>                        else (fromSqlMinutes sch)  - (fromSqlMinutes osw) - (fromSqlMinutes osr) - (fromSqlMinutes oso) - (fromSqlMinutes ltw) -  (fromSqlMinutes ltr) - (fromSqlMinutes lto) - (fromSqlMinutes nb)
>                     , pMoc = fromSql moc
>                     }

Retrieve all the scheduled periods within the given time range
-- usually the scheduling range -- that may be cancelled just
prior to observing.

> getDiscretionaryPeriods :: Connection -> DateTime -> Minutes -> IO [Period]
> getDiscretionaryPeriods cnn dt dur = do 
>   result <- quickQuery' cnn query xs 
>   -- get periods except for its session field
>   let ps' = toPeriodList result
>   -- get associated sessions
>   ss <- mapM (flip getSessionFromPeriod cnn) . map peId $ ps'
>   -- you complete me
>   let ps = map (\(p, s) -> p {session = s}) . zip ps' $ ss
>   -- but only want Open and Windowed periods, i.e., discretionary
>   return $ sort $ filter (\p -> (sType . session $ p) `elem` [Open, Windowed]) ps
>   where
>     xs = [toSql . toSqlString $ dt, toSql .toSqlString . addMinutes dur $ dt]
>     query = "SELECT p.id, p.session_id, p.start, p.duration, p.score, state.abbreviation, p.forecast, p.backup FROM periods AS p, period_states AS state WHERE state.id = p.state_id AND state.abbreviation = 'S' AND p.start >= ? AND p.start < ?;"
>     toPeriodList = map toPeriod
>     toPeriod (id:sid:start:durHrs:score:state:forecast:backup:[]) =
>       defaultPeriod { peId = fromSql id
>                     , startTime = sqlToDateTime start
>                     , duration = fromSqlMinutes durHrs
>                     , pScore = fromSql score
>                     , pState = deriveState . fromSql $ state
>                     , pForecast = sqlToDateTime forecast
>                     , pBackup = fromSql backup
>                     , pDuration = fromSqlMinutes durHrs
>                     }
>     toSessionId (id:sid:start:durHrs:score:state:forecast:backup:[]) = fromSql sid


> sqlToDateTime :: SqlValue -> DateTime
> sqlToDateTime dt = fromJust . fromSqlString . fromSql $ dt

> sqlToDate :: SqlValue -> DateTime
> sqlToDate dt = fromJust . fromSqlDateString . fromSql $ dt

> putPeriods :: [Period] -> Maybe StateType -> IO ()
> putPeriods ps state = do
>   cnn <- connect
>   result <- mapM (putPeriod cnn state) ps
>   return ()

Here we add a new period to the database.  
Initialize the Period in the Pending state.
Since Antioch is creating it,
we will set the Period_Accounting.scheduled field
and the associated receviers using the session's receivers.

> putPeriod :: Connection -> Maybe StateType -> Period -> IO ()
> putPeriod cnn mstate p = do
>   -- what state to use?
>   let state = if isNothing mstate then pState p else fromJust mstate
>   -- make an entry in the periods_accounting table; if this period is 
>   -- to be in the Scheduled state, init the time accounting's scheduled field
>   let scheduled = if state == Scheduled then duration p else 0
>   accounting_id <- putPeriodAccounting cnn scheduled
>   -- is this period part of a window?
>   let window = find (periodInWindow p) (windows . session $ p)
>   let winId = if (isNothing window) then SqlNull else (toSql . wId . fromJust $ window)
>   -- what should the id be for the state?
>   periodStates <- getPeriodStates cnn
>   let stateId = getPeriodStateId state periodStates
>   -- now for the period itself
>   quickQuery' cnn query (xs accounting_id winId stateId) 
>   commit cnn
>   pId <- getNewestID cnn "periods"
>   -- init the rcvrs associated w/ this period
>   putPeriodReceivers cnn p pId
>   -- now, mark if a window got scheduled early by this period
>   --updateWindow cnn p
>   commit cnn
>   -- finally, track changes in the DB by filling in the reversion tables
>   putPeriodReversion cnn p accounting_id stateId
>   commit cnn
>     where
>       xs a w stateId = [toSql . sId . session $ p
>              , toSql $ (toSqlString . startTime $ p) 
>              , minutesToSqlHrs . duration $ p
>              , toSql . pScore $ p
>              , toSql . toSqlString . pForecast $ p
>              , toSql . pBackup $ p
>              , toSql a
>              , w
>              , toSql stateId
>             ]
>       query = "INSERT INTO periods (session_id, start, duration, score, forecast, backup, accounting_id, window_id, state_id, moc_ack) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, false);"

When we create a period, we are going to associate the rcvrs from the session
to it's period (they can be changed later by schedulers)

> putPeriodReceivers :: Connection -> Period -> Int -> IO ()
> putPeriodReceivers cnn p pId = do
>     -- the rcvrs to put are those from the session
>     let rcvrs = concat . receivers . session $ p 
>     mapM (putPeriodReceiver cnn pId) rcvrs
>     return ()

Creates a new entry in the periods_receivers table.

> putPeriodReceiver :: Connection -> Int -> Receiver -> IO ()
> putPeriodReceiver cnn pId rcvr = do
>   -- get the rcvr id from DB
>   rcvrId <- getRcvrId cnn rcvr
>   quickQuery' cnn query (xs pId rcvrId) 
>   commit cnn
>     where
>       xs pId rcvrId = [toSql pId
>                      , toSql rcvrId
>                       ]
>       query = "INSERT INTO periods_receivers (period_id, receiver_id) VALUES (?, ?);"

> updateWindow :: Connection -> Period -> IO ()
> updateWindow cnn p = handleSqlError $ do
>   -- select the period to get its period id
>   result <- quickQuery' cnn pquery pxs 
>   let periodId = fromSqlInt . head . head $ result
>   -- search session's windows for first intersecting window
>   let window = find (periodInWindow p) (windows . session $ p)
>   if window == Nothing then return ()
>                        -- update window with the period_id
>                        else updateWindow' cnn periodId (wId . fromJust $ window)
>     where
>       pquery = "SELECT p.id FROM periods AS p \
>              \ WHERE p.session_id = ? AND p.start = ? AND p.duration = ?;"
>       pxs = [toSql . sId . session $ p
>            , toSql . toSqlString . startTime $ p
>            , minutesToSqlHrs . duration $ p
>             ]

> updateWindow' :: Connection -> Int -> Int -> IO ()
> updateWindow' cnn periodId windowId = handleSqlError $ do
>   result <- quickQuery' cnn wquery wxs
>   return ()
>     where
>       wquery = "UPDATE windows SET period_id = ? WHERE id = ?;"
>       wxs = [toSql periodId, toSql windowId]

> minutesToSqlHrs :: Minutes -> SqlValue
> minutesToSqlHrs mins = toSql $ (/(60.0::Float)) . fromIntegral $ mins 

Creates a new period accounting row, and returns this new rows ID.  Note that the
scheduled field's value is passed in.

> putPeriodAccounting :: Connection -> Int -> IO Int
> putPeriodAccounting cnn scheduled = do
>   quickQuery' cnn query xs
>   result <- quickQuery' cnn queryId xsId
>   return $ toId result
>     where
>       xs = [minutesToSqlHrs scheduled]
>       query = "INSERT INTO periods_accounting (scheduled, not_billable, other_session_weather, other_session_rfi, other_session_other, lost_time_weather, lost_time_rfi, lost_time_other, short_notice, description) VALUES (?, 0.0, 0.0, 0.0, 0.0,  0.0, 0.0, 0.0, 0.0, '')"
>       xsId = []
>       queryId = "SELECT MAX(id) FROM periods_accounting"
>       toId [[x]] = fromSql x

Change the state of all given periods 

> movePeriodsToDeleted ps = movePeriodsToState ps Deleted
> movePeriodsToScheduled ps = movePeriodsToState ps Scheduled

> movePeriodsToState :: [Period] -> StateType -> IO ()
> movePeriodsToState ps state = do
>   cnn <- connect
>   periodStates <- getPeriodStates cnn
>   let theStatesId = getPeriodStateId state periodStates
>   result <- mapM (movePeriodToState' cnn theStatesId) ps
>   return ()
>     where
>   movePeriodToState' cnn stateId p = movePeriodToState cnn (peId p) stateId

Changes the state of a Period.

> movePeriodToState :: Connection -> Int -> Int -> IO ()
> movePeriodToState cnn periodId stateId = handleSqlError $ do
>   result <- quickQuery' cnn query xs
>   commit cnn
>   return ()
>     where
>       query = "UPDATE periods SET state_id = ? WHERE id = ?;"
>       xs = [toSql stateId, toSql periodId]

Retrieves from the DB a mapping of row id to period state.

> getPeriodStates :: Connection -> IO ([(Int, StateType)])
> getPeriodStates cnn = do
>     r <- quickQuery' cnn query xs
>     return $ map toStates r
>   where
>     xs = []
>     query = "SELECT abbreviation, id FROM period_states;"
>     toStates (ab:id:[]) = (fromSql id, deriveState . fromSql $ ab)

Given a period state and the mapping to the states primary ID in the DB,
returns the appropriate primary ID.

> getPeriodStateId :: StateType -> [(Int, StateType)] -> Int
> getPeriodStateId periodState mapping = fst . fromJust $ find findState mapping
>   where
>     findState (id, state) = state == periodState

> updatePeriodScore :: Connection -> Int -> DateTime -> Score -> IO ()
> updatePeriodScore cnn pId dt score = handleSqlError $ do
>   result <- quickQuery' cnn query xs
>   commit cnn
>   return ()
>     where
>       query = "UPDATE periods SET score = ?, forecast = ? WHERE id = ?;"
>       xs = [toSql score, toSql . toSqlString $ dt, toSql pId]

> updatePeriodMOC :: Connection -> Int -> Maybe Bool -> IO ()
> updatePeriodMOC cnn pId moc = handleSqlError $ do
>   result <- quickQuery' cnn query xs
>   commit cnn
>   return ()
>     where
>       query = "UPDATE periods SET moc = ? WHERE id = ?;"
>       xs = [toSql moc, toSql pId]

> updateCompletedSessions :: [Session] -> IO ()
> updateCompletedSessions ss =  handleSqlError $ do
>   cnn <- connect
>   result <- mapM (updateSessionComplete cnn) ss
>   return ()

> updateSessionComplete :: Connection -> Session ->  IO ()
> updateSessionComplete cnn s = handleSqlError $ do
>   print ("updating complete flag for session: ", sName s, sId s)
>   result <- quickQuery' cnn query xs
>   commit cnn
>   return ()
>     where
>       query = "UPDATE status SET complete = ? FROM sessions WHERE sessions.status_id = status.id and sessions.id = ?;"
>       xs = [toSql . sClosed $ s, toSql . sId $ s]
 
Utilities

What's the largest (i.e. newest) primary key in the given table?

> getNewestID :: Connection -> String -> IO Int
> getNewestID cnn table = do
>     r <- quickQuery' cnn query xs
>     return $ toId r
>   where
>     xs = [] 
>     query = "SELECT MAX(id) FROM " ++ table
>     toId [[x]] = fromSql x
