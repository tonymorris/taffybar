-- | This is a simple text widget that updates its contents by calling
-- a callback at a set interval.
module System.Taffybar.Widget.Generic.PollingLabel
  ( pollingLabelNew
  , pollingLabelNewWithTooltip
  ) where

import           Control.Exception.Enclosed as E
import           Control.Monad
import           Control.Monad.IO.Class
import           Data.GI.Gtk.Threading
import qualified Data.Text as T
import           GI.Gtk
import qualified Graphics.UI.Gtk as Gtk2hs
import           System.Taffybar.Compat.GtkLibs
import           System.Taffybar.Util
import           System.Taffybar.Widget.Util

-- | Create a new widget that updates itself at regular intervals.  The
-- function
--
-- > pollingLabelNew initialString cmd interval
--
-- returns a widget with initial text @initialString@. The widget forks a thread
-- to update its contents every @interval@ seconds. The command should return a
-- string with any HTML entities escaped. This is not checked by the function,
-- since Pango markup shouldn't be escaped. Proper input sanitization is up to
-- the caller.
--
-- If the IO action throws an exception, it will be swallowed and the label will
-- not update until the update interval expires.
pollingLabelNew
  :: MonadIO m
  => String -- ^ Initial value for the label
  -> Double -- ^ Update interval (in seconds)
  -> IO String -- ^ Command to run to get the input string
  -> m Gtk2hs.Widget
pollingLabelNew initialString interval cmd =
  pollingLabelNewWithTooltip initialString interval $ (, Nothing) <$> cmd

pollingLabelNewWithTooltip
  :: MonadIO m
  => String -- ^ Initial value for the label
  -> Double -- ^ Update interval (in seconds)
  -> IO (String, Maybe String) -- ^ Command to run to get the input string
  -> m Gtk2hs.Widget
pollingLabelNewWithTooltip initialString interval cmd =
  liftIO $ fromGIWidget =<< do
    grid <- gridNew
    label <- labelNew $ Just $ T.pack initialString

    let updateLabel (labelStr, tooltipStr) =
          postGUIASync $ do
            labelSetMarkup label $ T.pack labelStr
            widgetSetTooltipMarkup label $ T.pack <$> tooltipStr

    _ <- onWidgetRealize label $ void $ foreverWithDelay interval $
      E.tryAny cmd >>= either (const $ return ()) updateLabel

    vFillCenter label
    vFillCenter grid
    containerAdd grid label
    widgetShowAll grid
    toWidget grid
