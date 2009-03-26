> module Antioch.Plots where

> import Antioch.DateTime (DateTime)
> import Graphics.Gnuplot.Simple

Histogram plots

> histStyle :: Maybe String -> PlotStyle
> histStyle = PlotStyle Boxes (CustomStyle [])

> histogramPlot       :: [Attribute] -> [(Float, Float)] -> IO ()
> histogramPlot attrs =
>     plotPathStyle attrs (histStyle Nothing) . adjustHistData

> histogramPlots             :: [Attribute] -> [(Maybe String, [(Float, Float)])] -> IO ()
> histogramPlots attrs plots =
>     plotPathsStyle attrs [(histStyle t, adjustHistData xys) | (t, xys) <- plots]

Our stats functions return histograms w/ the following format:
[(b0, n0), (b1, n1), .. ]
Where n0 specifies the number of values at and below the value of b0, and
      n1 specifies the number of values at and below the value of b1, etc.
Unfortunetly, these plot routines don't interpret histograms this way. It 
seems that they shift everything to the right by half a bin.
TBF: In addition, I (PRM) can't make heads or tails of what's going on when
irregularly spaced bins are used, so right now we are only supporting
regularly spaced bins.

> adjustHistData      :: [(Float, Float)] -> [(Float, Float)]
> adjustHistData xs
>     | length xs > 1 = map adjust xs
>     | otherwise     = xs
>  where
>     adjust (x, y) = (x - step, y)
>     step = (x2 - x1) / 2.0
>     ((x1, _) : (x2, _) : _) = xs
> -- TBF: irregularly spaced bins don't seem to work???
> --adjustHistData (x:[])  = []
> --adjustHistData (x1:x2:xs) = (b1 - ((b2 - b1)/2.0), v1):adjustHistData (x2:xs)

Line plots

> lineStyle :: Maybe String -> PlotStyle
> lineStyle = PlotStyle Lines (CustomStyle [])

> linePlots             :: [Attribute] -> [(Maybe String, [(Float, Float)])] -> IO ()
> linePlots attrs plots =
>     plotPathsStyle attrs [(lineStyle t, xys) | (t, xys) <- plots]

> errorBarPlot :: [Attribute] -> [(Float, Float, Float)] -> IO ()
> errorBarPlot = plotErrorBars

Scatter plots

> scatterStyle :: Maybe String -> PlotStyle
> scatterStyle = PlotStyle Points (CustomStyle [])

> scatterPlot       :: [Attribute] -> [(Float, Float)] -> IO ()
> scatterPlot attrs = 
>     plotPathStyle attrs $ scatterStyle Nothing

> scatterPlots             :: [Attribute] -> [(Maybe String, [(Float, Float)])] -> IO ()
> scatterPlots attrs plots =
>     plotPathsStyle attrs [(scatterStyle t, xys) | (t, xys) <- plots]
