-----------------------------------------------------------------------------
-- |
-- Module      : System.Taffybar.Information.EWMHDesktopInfo
-- Copyright   : (c) José A. Romero L.
-- License     : BSD3-style (see LICENSE)
--
-- Maintainer  : José A. Romero L. <escherdragon@gmail.com>
-- Stability   : unstable
-- Portability : unportable
--
-- Functions to access data provided by the X11 desktop via EWHM hints. This
-- module requires that the EwmhDesktops hook from the XMonadContrib project
-- be installed in your @~\/.xmonad\/xmonad.hs@ configuration:
--
-- > import XMonad
-- > import XMonad.Hooks.EwmhDesktops (ewmh)
-- >
-- > main = xmonad $ ewmh $ ...
--
-----------------------------------------------------------------------------

module System.Taffybar.Information.EWMHDesktopInfo
  ( X11Window      -- re-exported from X11DesktopInfo
  , X11WindowHandle
  , WorkspaceIdx(..)
  , EWMHIcon(..)
  , EWMHIconData
  , withDefaultCtx -- re-exported from X11DesktopInfo
  , isWindowUrgent -- re-exported from X11DesktopInfo
  , getCurrentWorkspace
  , getVisibleWorkspaces
  , getWorkspaceNames
  , switchToWorkspace
  , switchOneWorkspace
  , withEWMHIcons
  , getWindowTitle
  , getWindowClass
  , getWindowIconsData
  , getActiveWindowTitle
  , getWindows
  , getWindowHandles
  , getWorkspace
  , focusWindow
  ) where

import Control.Applicative
import Control.Monad.Trans.Class
import Data.Maybe
import Data.Tuple
import Data.Word
import Debug.Trace
import Foreign.ForeignPtr
import Foreign.Marshal.Array
import Foreign.Ptr
import Foreign.Storable
import System.Taffybar.Information.SafeX11

import Prelude

import System.Taffybar.Information.X11DesktopInfo

-- | Convenience alias for a pair of the form (props, window), where props is a
-- tuple of the form (workspace index, window title, window class), and window
-- is the internal ID of an open window.
type X11WindowHandle = ((WorkspaceIdx, String, String), X11Window)

newtype WorkspaceIdx = WSIdx Int
                     deriving (Show, Read, Ord, Eq)

-- A super annoying detail of the XGetWindowProperty interface is that: "If the
-- returned format is 32, the returned data is represented as a long array and
-- should be cast to that type to obtain the elements." This means that even
-- though only the 4 least significant bits will ever contain any data, the
-- array that is returned from X11 can have a larger word size. This means that
-- we need to manipulate the underlying data in annoying ways to pass it to gtk
-- appropriately.
type PixelsWordType = Word64

type EWMHIconData = (ForeignPtr PixelsWordType, Int)

data EWMHIcon = EWMHIcon
  { width :: Int
  , height :: Int
  , pixelsARGB :: Ptr PixelsWordType
  } deriving (Show, Eq)

noFocus :: String
noFocus = "..."

-- | Retrieve the index of the current workspace in the desktop,
-- starting from 0.
getCurrentWorkspace :: X11Property WorkspaceIdx
getCurrentWorkspace = WSIdx <$> readAsInt Nothing "_NET_CURRENT_DESKTOP"

-- | Retrieve the indexes of all currently visible workspaces
-- with the active workspace at the head of the list.
getVisibleWorkspaces :: X11Property [WorkspaceIdx]
getVisibleWorkspaces = do
  vis <- getVisibleTags
  allNames <- map swap <$> getWorkspaceNames
  cur <- getCurrentWorkspace
  return $ cur : mapMaybe (`lookup` allNames) vis

-- | Return a list with the names of all the workspaces currently
-- available.
getWorkspaceNames :: X11Property [(WorkspaceIdx, String)]
getWorkspaceNames = go <$> readAsListOfString Nothing "_NET_DESKTOP_NAMES"
  where go = zip [WSIdx i | i <- [0..]]

-- | Ask the window manager to switch to the workspace with the given
-- index, starting from 0.
switchToWorkspace :: WorkspaceIdx -> X11Property ()
switchToWorkspace (WSIdx idx) = do
  cmd <- getAtom "_NET_CURRENT_DESKTOP"
  sendCommandEvent cmd (fromIntegral idx)

-- | Move one workspace up or down from the current workspace
switchOneWorkspace :: Bool -> Int -> X11Property ()
switchOneWorkspace dir end = do
  cur <- getCurrentWorkspace
  switchToWorkspace $ if dir then getPrev cur end else getNext cur end

-- | Check for corner case and switch one workspace up
getPrev :: WorkspaceIdx -> Int -> WorkspaceIdx
getPrev (WSIdx idx) end
  | idx > 0 = WSIdx $ idx-1
  | otherwise = WSIdx end

-- | Check for corner case and switch one workspace down
getNext :: WorkspaceIdx -> Int -> WorkspaceIdx
getNext (WSIdx idx) end
  | idx < end = WSIdx $ idx+1
  | otherwise = WSIdx 0

-- | Get the title of the given X11 window.
getWindowTitle :: X11Window -> X11Property String
getWindowTitle window = do
  let w = Just window
  prop <- readAsString w "_NET_WM_NAME"
  case prop of
    "" -> readAsString w "WM_NAME"
    _  -> return prop

-- | Get the class of the given X11 window.
getWindowClass :: X11Window -> X11Property String
getWindowClass window = readAsString (Just window) "WM_CLASS"

-- | Get EWMHIconData for the given X11Window
getWindowIconsData :: X11Window -> X11Property (Maybe EWMHIconData)
getWindowIconsData window = do
  dpy <- getDisplay
  atom <- getAtom "_NET_WM_ICON"
  lift $ rawGetWindowPropertyBytes 32 dpy atom window

-- | Operate on the data contained in 'EWMHIconData' in the easier to interact
-- with format offered by 'EWMHIcon'. This function is much like
-- 'withForeignPtr' in that the 'EWMHIcon' values that are provided to the
-- callable argument should not be kept around in any way, because it can not be
-- guaranteed that the finalizer for the memory to which those icon objects
-- point will not be executed, after the call to 'withEWMHIcons' completes.
withEWMHIcons :: EWMHIconData -> ([EWMHIcon] -> IO a) -> IO a
withEWMHIcons (fptr, size) action =
  withForeignPtr fptr ((>>= action) . parseIcons size)

-- | Split icon raw integer data into EWMHIcons.
-- Each icon raw data is an integer for width,
--   followed by height,
--   followed by exactly (width*height) ARGB pixels,
--   optionally followed by the next icon.
-- This function should not be made public, because its return value contains
-- (sub)pointers whose allocation we do not control.
parseIcons :: Int -> Ptr PixelsWordType -> IO [EWMHIcon]
parseIcons 0 _ = return []
parseIcons totalSize arr = do
  iwidth <- fromIntegral <$> peek arr
  iheight <- fromIntegral <$> peekElemOff arr 1
  let pixelsPtr = advancePtr arr 2
      thisSize = iwidth * iheight
      newArr = advancePtr pixelsPtr thisSize
      thisIcon =
        EWMHIcon
        { width = iwidth
        , height = iheight
        , pixelsARGB = pixelsPtr
        }
      getRes newSize
        | newSize < 0 = trace "This should not happen parseIcons" return []
        | otherwise = (thisIcon :) <$> parseIcons newSize newArr -- Keep going
  getRes $ totalSize - fromIntegral (thisSize + 2)

withActiveWindow :: (X11Window -> X11Property String) -> X11Property String
withActiveWindow getProp = do
  awt <- readAsListOfWindow Nothing "_NET_ACTIVE_WINDOW"
  let w = listToMaybe $ filter (>0) awt
  maybe (return noFocus) getProp w

-- | Get the title of the currently focused window.
getActiveWindowTitle :: X11Property String
getActiveWindowTitle = withActiveWindow getWindowTitle

-- | Return a list of all windows
getWindows :: X11Property [X11Window]
getWindows = readAsListOfWindow Nothing "_NET_CLIENT_LIST"

-- | Return a list of X11 window handles, one for each window open. Refer to the
-- documentation of 'X11WindowHandle' for details on the structure returned.
getWindowHandles :: X11Property [X11WindowHandle]
getWindowHandles = do
  windows <- getWindows
  workspaces <- mapM getWorkspace windows
  wtitles <- mapM getWindowTitle windows
  wclasses <- mapM getWindowClass windows
  return $ zip (zip3 workspaces wtitles wclasses) windows

-- | Return the index (starting from 0) of the workspace on which the
-- given window is being displayed.
getWorkspace :: X11Window -> X11Property WorkspaceIdx
getWorkspace window = WSIdx <$> readAsInt (Just window) "_NET_WM_DESKTOP"

-- | Ask the window manager to give focus to the given window.
focusWindow :: X11Window -> X11Property ()
focusWindow wh = do
  cmd <- getAtom "_NET_ACTIVE_WINDOW"
  sendWindowEvent cmd (fromIntegral wh)
