# Copyright (C) 2009 Associated Universities, Inc. Washington DC, USA.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software Foundation,
# Inc., 675 Mass Ave Cambridge, MA 02139, USA.
#
# Correspondence concerning GBT software should be addressed as follows:
#     GBT Operations
#     National Radio Astronomy Observatory
#     P. O. Box 2
#     Green Bank, WV 24944-0002 USA

if __name__ == "__main__":
    import sys
    sys.path[1:1] = [".."]

from datetime import datetime, timedelta
from CleoDBImport import CleoDBImport
import unittest
import pg

class TestCleoDBImport(unittest.TestCase):

    def setUp(self):
        # use a special DB because we'll be cleaning this one out everytime.
        self.dbname = "weather_import_unit_tests"
        self.forecast = datetime.utcnow().replace(hour=6, minute=0, second=0, microsecond=0)
        self.import_time = datetime.utcnow().replace(second = 0
                                                   , microsecond = 0)
        self.cleo = CleoDBImport(self.forecast, self.dbname, "tests")

    def testGetForecatTypeId(self):
        self.assertEquals(9, self.cleo.getForecastTypeId(5))
        self.assertEquals(10, self.cleo.getForecastTypeId(6))
        self.assertEquals(None, self.cleo.getForecastTypeId(-1))
        self.assertEquals(None, self.cleo.getForecastTypeId(99))

    def testGetForecatTypeFromTimestamp(self):
        now = datetime.utcnow()

        dt = now.replace(hour=5, minute=0, second=0, microsecond=0)
        self.assertEquals(9, self.cleo.getForecastTypeIdFromTimestamp(dt))
        dt = now.replace(hour=6, minute=0, second=0, microsecond=0)
        self.assertEquals(9, self.cleo.getForecastTypeIdFromTimestamp(dt))
        dt = now.replace(hour=7, minute=0, second=0, microsecond=0)
        self.assertEquals(9, self.cleo.getForecastTypeIdFromTimestamp(dt))
        dt = now.replace(hour=11, minute=0, second=0, microsecond=0)
        self.assertEquals(9, self.cleo.getForecastTypeIdFromTimestamp(dt))
        dt = now.replace(hour=12, minute=0, second=0, microsecond=0)
        self.assertEquals(10, self.cleo.getForecastTypeIdFromTimestamp(dt))


        dt = self.forecast +  timedelta(days = 3, seconds = (60*60*6))
        self.assertEquals(22, self.cleo.getForecastTypeIdFromTimestamp(dt))

    def testFindForecastFiles(self):

        files = self.cleo.findForecastFiles()        
        exp = ('tests/Forecasts_09_12_07_11h40m52s/time_HotSprings_09_12_07_11h40m52s.txt'
             , 'tests/Forecasts_09_12_07_11h40m57s/time_avrg_09_12_07_11h40m57s.txt')
        self.assertEquals(exp, files)        

    def testRead(self):
        cleo = CleoDBImport(6, "")
        cleo.forecast_time = datetime(2009, 12, 1, 6, 0, 0)
        cleo.read("tests/test_freq_vals.txt", "tests/test_winds.txt")

        # Ground File - wind speeds

        # First row
        timestamp = cleo.data[0][0]    # 2009-11-30 23:00:00 UTC
        # We expect this to be the first timestamp since cleo gives
        # you a 12 hour buffer from *before* you *asked* for the forecasts
        # And we asked for these at 2009-12-1 11:40:00 (rounded to hour)
        expTimestamp = datetime(2009, 11, 30, 23, 0, 0)
        self.assertEquals(expTimestamp, timestamp)

        # The mph wind is something you can see for yourself in the file
        wind_mph = cleo.data[0][1]['speed_mph']
        self.assertEquals(9.44725, wind_mph)
        # The rest of these we derive from the file
        wind_ms = cleo.data[0][1]['speed_ms']
        self.assertAlmostEquals(4.3556981244, wind_ms, 4)  
        # Should be a really old forecast
        ftype_id = cleo.data[0][1]['forecast_type_id']
        self.assertEquals(9, ftype_id)

        # Middle row
        timestamp = cleo.data[52][0]
        expTimestamp = datetime(2009, 12, 3, 3, 0, 0)
        self.assertEquals(expTimestamp, timestamp)
        wind_mph = cleo.data[52][1]['speed_mph']
        self.assertEquals(15.617, wind_mph)
        wind_ms = cleo.data[52][1]['speed_ms']
        self.assertAlmostEquals(4.6497772, wind_ms, 4)     
        ftype_id = cleo.data[52][1]['forecast_type_id']
        self.assertEquals(16, ftype_id)
        
        # Last row
        timestamp = cleo.data[91][0]
        expTimestamp = datetime(2009, 12, 4, 18, 0, 0)
        self.assertEquals(expTimestamp, timestamp)
        wind_mph = cleo.data[91][1]['speed_mph']
        self.assertEquals(7.42325, wind_mph)
        wind_ms = cleo.data[91][1]['speed_ms']
        self.assertAlmostEquals(3.888053, wind_ms, 4)     
        ftype_id = cleo.data[91][1]['forecast_type_id']
        self.assertEquals(23, ftype_id)

        # Atmosphere File

        # First row
        self.assertEquals(50, len(cleo.data[0][1]['tauCleo']))
        self.assertEquals(50, len(cleo.data[0][1]['tSysCleo']))
        self.assertEquals(50, len(cleo.data[0][1]['tAtmCleo']))
        tau = cleo.data[0][1]['tauCleo'][0]  # tau @ 1 GHz @ 2009-11-30 23:00
        self.assertEquals(0.00681057834902, tau)
        tau = cleo.data[0][1]['tauCleo'][21]  # tau @ 22 GHz @ 2009-11-30 23:00
        self.assertEquals(0.0553289857371, tau)
        tAtm = cleo.data[0][1]['tAtmCleo'][49] # tatm @50 GHz @ 2009-11-30 23
        self.assertEquals(256.986808314, tAtm)

        # Middle row
        row = 52
        self.assertEquals(50, len(cleo.data[row][1]['tauCleo']))
        self.assertEquals(50, len(cleo.data[row][1]['tSysCleo']))
        self.assertEquals(50, len(cleo.data[row][1]['tAtmCleo']))
        tau = cleo.data[row][1]['tauCleo'][0]  # tau @ 1 GHz @ ?
        self.assertEquals(0.00655953948891, tau)
        tau = cleo.data[row][1]['tauCleo'][21]  # tau @22 GHz @ ?
        self.assertEquals(0.290061676655, tau)
        tAtm = cleo.data[row][1]['tAtmCleo'][49] # tatm @50 GHz @ ? 
        self.assertEquals(275.21046553, tAtm)

    def testInsert(self):

        # truncat tables of interest
        cnn = pg.connect(user = "dss", dbname = self.dbname) #"weather_unit_tests")
        tables = ['weather_station2'
                , 'forecast_by_frequency'
                , 'forecasts'
                , 'forecast_times'
                , 'import_times'
                , 'weather_dates']
        q = "TRUNCATE TABLE"
        for t in tables:
            q += " %s," % t
        q = q[:-1] + " CASCADE;"
        cnn.query(q)
       
        # check that these tables are empty 
        for t in tables:
            q = "SELECT * FROM %s" % t
            r = cnn.query(q)
            self.assertEquals(0, len(r.dictresult()))

        # create test data
        dt = datetime(2009, 1, 22, 6, 0, 0)
        forecast_type_id = 13
        tauCleo   = [1.0, 2.0, 3.0]
        tSysCleo  = [4.0, 5.0, 6.0]
        tAtmCleo  = [7.0, 8.0, 9.0]
        speed_ms  = 10.0
        speed_mph = 11.0
        dataDct = dict(forecast_type_id = forecast_type_id
                     , speed_ms         = speed_ms
                     , speed_mph        = speed_mph
                     , tauCleo          = tauCleo
                     , tSysCleo         = tSysCleo
                     , tAtmCleo         = tAtmCleo
                     )
        self.cleo.data = [(dt, dataDct)]             
        
        # insert the data!
        self.cleo.insert()

        # test what's in the DB!
        # first check that only one forecast time is in there
        q = "SELECT * FROM forecast_times"
        r = cnn.query(q)
        self.assertEquals(1, len(r.dictresult()))
        expDt = r.dictresult()[0]['date']
        self.assertEquals(expDt, str(self.forecast))

        # first check that only one forecast time is in there
        q = "SELECT * FROM import_times"
        r = cnn.query(q)
        self.assertEquals(1, len(r.dictresult()))
        expDt = r.dictresult()[0]['date']
        self.assertEquals(expDt, str(self.import_time))

        # first check that only one forecast time is in there
        q = "SELECT * FROM weather_dates"
        r = cnn.query(q)
        self.assertEquals(1, len(r.dictresult()))
        expDt = r.dictresult()[0]['date']
        self.assertEquals(expDt, str(dt))

        # only one entry in forecasts
        q = "SELECT * from forecasts"
        r = cnn.query(q)
        self.assertEquals(1, len(r.dictresult()))
        self.assertEquals(speed_ms, r.dictresult()[0]['wind_speed'])
        self.assertEquals(speed_mph, r.dictresult()[0]['wind_speed_mph'])

        # only three entries in forecast by frequency
        q = "SELECT * from forecast_by_frequency"
        r = cnn.query(q)
        self.assertEquals(3, len(r.dictresult()))
        for i in range(3):
            self.assertEquals(tauCleo[i], r.dictresult()[i]['opacity'])
            self.assertEquals(tAtmCleo[i], r.dictresult()[i]['tsys'])

        # insert the data agains
        self.cleo.insert()

        # no changes in database
        q = "SELECT * FROM weather_dates"
        r = cnn.query(q)
        self.assertEquals(1, len(r.dictresult()))
        q = "SELECT * from forecasts"
        r = cnn.query(q)
        self.assertEquals(1, len(r.dictresult()))
        q = "SELECT * from forecast_by_frequency"
        r = cnn.query(q)
        self.assertEquals(3, len(r.dictresult()))

if __name__ == "__main__":
    unittest.main()
    # for more verbosity:
    #suite = unittest.TestLoader().loadTestsFromTestCase(TestCleoDBImport)
    #unittest.TextTestRunner(verbosity=2).run(suite)
    