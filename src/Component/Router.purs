-- | The `Router` component is the root of our Halogen application. Every other component is a 
-- | direct descendent of this component. We'll use the router to choose which component to render
-- | given a particular `Route` and to manage the user's location in the application.
-- |
-- | See `Main` to understand how this component is used as the root of the application.
module Conduit.Component.Router where

import Prelude

import Conduit.Capability.LogMessages (class LogMessages)
import Conduit.Capability.Navigate (class Navigate, navigate)
import Conduit.Capability.Now (class Now)
import Conduit.Capability.Resource.Article (class ManageArticle)
import Conduit.Capability.Resource.Comment (class ManageComment)
import Conduit.Capability.Resource.Tag (class ManageTag)
import Conduit.Capability.Resource.User (class ManageUser)
import Conduit.Component.Utils (OpaqueSlot, busEventSource)
import Conduit.Data.Profile (Profile)
import Conduit.Data.Route (Route(..), routeCodec)
import Conduit.Page.Editor as Editor
import Conduit.Page.Home as Home
import Conduit.Page.Login as Login
import Conduit.Page.Profile (Tab(..))
import Conduit.Page.Profile as Profile
import Conduit.Page.Register as Register
import Conduit.Page.Settings as Settings
import Conduit.Page.ViewArticle as ViewArticle
import Control.Monad.Reader (class MonadAsk, ask)
import Data.Either (hush)
import Data.Foldable (elem)
import Data.Maybe (Maybe(..), fromMaybe, isJust)
import Data.Symbol (SProxy(..))
import Effect.Aff.Bus (BusRW)
import Effect.Aff.Class (class MonadAff)
import Effect.Ref (Ref)
import Effect.Ref as Ref
import Halogen (liftEffect)
import Halogen as H
import Halogen.HTML as HH
import Routing.Duplex as RD
import Routing.Hash (getHash)

type State =
  { route :: Maybe Route 
  , currentUser :: Maybe Profile
  }

data Query a
  = Navigate Route a

data Action 
  = Initialize 
  | HandleUserBus (Maybe Profile)

type ChildSlots = 
  ( home :: OpaqueSlot Unit
  , login :: OpaqueSlot Unit
  , register :: OpaqueSlot Unit
  , settings :: OpaqueSlot Unit
  , editor :: OpaqueSlot Unit
  , viewArticle :: OpaqueSlot Unit
  , profile :: OpaqueSlot Unit
  )

component
  :: forall m r
   . MonadAff m
  => MonadAsk { currentUser :: Ref (Maybe Profile), userBus :: BusRW (Maybe Profile) | r } m
  => Now m
  => LogMessages m
  => Navigate m
  => ManageUser m
  => ManageArticle m
  => ManageComment m
  => ManageTag m
  => H.Component HH.HTML Query Unit Void m
component = H.mkComponent
  { initialState: \_ -> { route: Nothing, currentUser: Nothing } 
  , render
  , eval: H.mkEval $ H.defaultEval { handleQuery = handleQuery }
  }
  where 
  handleAction :: Action -> H.HalogenM State Action ChildSlots Void m Unit
  handleAction = case _ of
    Initialize -> do
      -- first, we'll get the value of the current user and subscribe to updates any time the
      -- value changes
      { currentUser, userBus } <- ask
      _ <- H.subscribe (HandleUserBus <$> busEventSource userBus)
      mbProfile <- liftEffect (Ref.read currentUser) 
      H.modify_ _ { currentUser = mbProfile }
      -- then, we'll get the route the user landed on
      initialRoute <- hush <<< (RD.parse routeCodec) <$> liftEffect getHash
      -- and, finally, we'll navigate to the new route (also setting the hash)
      navigate $ fromMaybe Home initialRoute
    
    HandleUserBus mbProfile -> do
      H.modify_ _ { currentUser = mbProfile }

  handleQuery :: forall a. Query a -> H.HalogenM State Action ChildSlots Void m (Maybe a)
  handleQuery = case _ of
    Navigate dest a -> do
      { route, currentUser } <- H.get 
      -- don't re-render unnecessarily if the route is unchanged
      when (route /= Just dest) do
        -- don't change routes if there is a logged-in user trying to access
        -- a route only meant to be accessible to a not-logged-in session
        unless (isJust currentUser && dest `elem` [ Login, Register ]) do
          H.modify_ _ { route = Just dest }
      pure (Just a)

  -- Display the login page instead of the expected page if there is no current user; a simple 
  -- way to restrict access.
  authorize :: Maybe Profile -> H.ComponentHTML Action ChildSlots m -> H.ComponentHTML Action ChildSlots m
  authorize mbProfile html = case mbProfile of
    Nothing ->
      HH.slot (SProxy :: _ "login") unit Login.component { redirect: false } absurd
    Just _ ->
      html
   
  render :: State -> H.ComponentHTML Action ChildSlots m
  render { route, currentUser } = case route of
    Just r -> case r of
      Home -> 
        HH.slot (SProxy :: _ "home") unit Home.component unit absurd
      Login -> 
        HH.slot (SProxy :: _ "login") unit Login.component { redirect: true } absurd
      Register -> 
        HH.slot (SProxy :: _ "register") unit Register.component unit absurd
      Settings -> 
        HH.slot (SProxy :: _ "settings") unit Settings.component unit absurd
          # authorize currentUser
      Editor -> 
        HH.slot (SProxy :: _ "editor") unit Editor.component { slug: Nothing } absurd
          # authorize currentUser
      EditArticle slug -> 
        HH.slot (SProxy :: _ "editor") unit Editor.component { slug: Just slug } absurd
          # authorize currentUser
      ViewArticle slug -> 
        HH.slot (SProxy :: _ "viewArticle") unit ViewArticle.component { slug } absurd
      Profile username -> 
        HH.slot (SProxy :: _ "profile") unit Profile.component { username, tab: ArticlesTab } absurd
      Favorites username -> 
        HH.slot (SProxy :: _ "profile") unit Profile.component { username, tab: FavoritesTab } absurd
    Nothing ->
      HH.div_ [ HH.text "Oh no! That page wasn't found." ]
      