{-# LANGUAGE TemplateHaskell, Rank2Types, NoMonomorphismRestriction, LambdaCase, RecordWildCards, FlexibleContexts #-}
import Graphics.Gloss
import Graphics.Gloss.Interface.Pure.Game
import Graphics.Gloss.Data.Vector
import Graphics.Gloss.Geometry.Angle

import Control.Monad.State
import Control.Monad.RWS

--import Control.Lens
import Lens.Micro.Platform

import Data.Maybe
import Text.Printf
import Debug.Trace

{-
  minigame
    done - shoot bullets with limited lifetime
    done - respawn player
    pick up health, weapon and ammo powerups
    touch lava that cause damage
    respawn items

  goals:
    rule based
    compositional with reusable small components
    intuitive and easy to use
    simple and efficient operational semantics and implementation (should be easy to imagine the compilation/codegen)

  events:
    collision between entities and client

-}

type Vec2 = Vector

_x = _1
_y = _2

-- entities

data Player
  = Player
  { _pPosition  :: Vec2
  , _pAngle     :: Float
  , _pHealth    :: Int
  , _pAmmo      :: Int
  , _pArmor     :: Int
  , _pShootTime :: Float
  } deriving Show

data Bullet
  = Bullet
  { _bPosition   :: Vec2
  , _bDirection  :: Vec2
  , _bDamage     :: Int
  , _bLifeTime   :: Float
  } deriving Show

data Weapon
  = Weapon
  { _wPosition   :: Vec2
  } deriving Show

data Ammo
  = Ammo
  { _aPosition   :: Vec2
  , _aQuantity   :: Int
  } deriving Show

data Armor
  = Armor
  { _rPosition   :: Vec2
  , _rQuantity   :: Int
  } deriving Show

data Spawn
  = Spawn
  { _sSpawnTime :: Float
  , _sEntity    :: Entity
  } deriving Show

data Entity
  = EPlayer Player
  | EBullet Bullet
  | EWeapon Weapon
  | EAmmo   Ammo
  | EArmor  Armor
  | PSpawn  Spawn
  deriving Show

concat <$> mapM makeLenses [''Player, ''Bullet, ''Weapon, ''Ammo, ''Armor, ''Spawn]

type Time = Float
type DTime = Float

collide :: Vec2 -> Float -> Int -> [(Entity,Int)] -> [Entity]
collide o r skipI ents = mapMaybe dispatch ents where
  f e d s = if magV (o - d) < r + s then Just e else Nothing
  dispatch (e,i)
    | i == skipI = Nothing
    | otherwise = case e of
        EPlayer a -> f e (a^.pPosition) 20
        EBullet a -> f e (a^.bPosition) 2
        EWeapon a -> f e (a^.wPosition) 10
        EAmmo a   -> f e (a^.aPosition) 8
        EArmor a  -> f e (a^.rPosition) 10
        _ -> Nothing

updateEntities :: Input -> [Entity] -> [Entity]
updateEntities input@Input{..} ents = do
  let ients = zip ents [0..]
      go _ (Nothing,x) = x
      go c (Just a,x) = c a : x
  flip foldMap ients $ \(e,i) -> case e of
    EPlayer p -> go EPlayer $ player input (collide (p^.pPosition) 20 i ients) p
    EBullet b -> go EBullet $ bullet time dtime (collide (b^.bPosition) 2 i ients) b
    EWeapon a -> go EWeapon $ weapon time dtime (collide (a^.wPosition) 10 i ients) a
    EAmmo   a -> go EAmmo $ ammo time dtime (collide (a^.aPosition) 8 i ients) a
    EArmor  a -> go EArmor $ armor time dtime (collide (a^.rPosition) 10 i ients) a
    PSpawn  a -> go PSpawn $ spawn time dtime a
    a -> [a]

myEvalRWS m a = evalRWS m a a

initialPlayer = Player
  { _pPosition  = (0,0)
  , _pAngle     = 0
  , _pHealth    = 100
  , _pAmmo      = 100
  , _pArmor     = 0
  , _pShootTime = 0
  }

spawn :: Time -> DTime -> Spawn -> (Maybe Spawn,[Entity])
spawn t dt = myEvalRWS $ do
  spawnTime <- view sSpawnTime
  if t < spawnTime then Just <$> get else do
    ent <- view sEntity
    tell [ent]
    return Nothing

player :: Input -> [Entity] -> Player -> (Maybe Player,[Entity])
player input@Input{..} c = myEvalRWS $ do
  -- move according input
  pAngle += rightmove * dtime
  angle <- use pAngle
  let direction = unitVectorAtAngle $ degToRad angle
  pPosition += mulSV (forwardmove * dtime) direction

  -- shoot
  shootTime <- view pShootTime
  when (shoot && shootTime < time) $ do
    pos <- use pPosition
    tell [EBullet $ Bullet (pos + mulSV 30 direction) (mulSV 150 direction) 1 2]
    pShootTime .= time + 0.1

  -- on collision:
    -- bullet --> dec armor or dec health
    -- weapon --> inc ammo and add weapon
    -- ammo   --> inc ammo
    -- armor  --> inc armor
  forM_ c $ \case
    EBullet b -> pHealth -= b^.bDamage
    EAmmo a   -> pAmmo += a^.aQuantity
    EArmor a  -> pArmor += a^.rQuantity
    EWeapon _ -> pAmmo += 10
    _ -> return ()
  -- death
  health <- use pHealth
  if health > 0 then Just <$> get else do
    tell [PSpawn $ Spawn (time + 2) $ EPlayer initialPlayer]
    return Nothing

bullet :: Time -> DTime -> [Entity] -> Bullet -> (Maybe Bullet,[Entity])
bullet t dt c = myEvalRWS $ do
  (u,v) <- use bDirection
  bPosition += (dt * u, dt * v)
  -- die on collision
  -- die on spent lifetime
  bLifeTime -= dt
  lifeTime <- use bLifeTime
  if lifeTime < 0 || not (null c) then return Nothing else Just <$> get

respawnOnTouch f t dt c = myEvalRWS $ do
  if null c then Just <$> get else do
    ent <- ask
    tell [PSpawn $ Spawn (t + 3) (f ent)]
    return Nothing

weapon :: Time -> DTime -> [Entity] -> Weapon -> (Maybe Weapon,[Entity])
weapon = respawnOnTouch EWeapon

ammo :: Time -> DTime -> [Entity] -> Ammo -> (Maybe Ammo,[Entity])
ammo = respawnOnTouch EAmmo

armor :: Time -> DTime -> [Entity] -> Armor -> (Maybe Armor,[Entity])
armor = respawnOnTouch EArmor

-----

data Input
  = Input
  { forwardmove :: Float
  , rightmove   :: Float
  , shoot       :: Bool
  , dtime       :: Float
  , time        :: Float
  } deriving Show

data World
  = World
  { _wEntities  :: [Entity]
  , _wInput     :: Input
  } deriving Show

makeLenses ''World

inputFun e w = w & wInput .~ i' where
  f Down = 100
  f Up = -100

  i@Input{..} = w^.wInput
  i' = case e of
    EventKey (Char 'w') s _ _ -> i {forwardmove = forwardmove + f s}
    EventKey (Char 's') s _ _ -> i {forwardmove = forwardmove - f s}
    EventKey (Char 'd') s _ _ -> i {rightmove = rightmove - f s}
    EventKey (Char 'a') s _ _ -> i {rightmove = rightmove + f s}
    EventKey (SpecialKey KeySpace) s _ _ -> i {shoot = s == Down}
    _ -> i

stepFun :: Float -> World -> World
stepFun dt = execState $ do
  -- update time
  wInput %= (\i -> i {dtime = dt, time = time i + dt})
  input <- use wInput
  wEntities %= updateEntities input

renderFun w = Pictures $ flip map (w^.wEntities) $ \case
  EPlayer p -> let (x,y) = p^.pPosition
                   gfx = Translate x y $ Rotate (-p^.pAngle) $ Pictures [Polygon [(-10,-6),(10,0),(-10,6)],Circle 20]
                   hud = Translate (-50) 250 $ Scale 0.2 0.2 $ Text $ printf "health:%d ammo:%d armor:%d" (p^.pHealth) (p^.pAmmo) (p^.pArmor)
               in Pictures [hud,gfx]
  EBullet b -> Translate x y $ Color green $ Circle 2 where (x,y) = b^.bPosition
  EWeapon a -> Translate x y $ Color blue $ Circle 10 where (x,y) = a^.wPosition
  EAmmo a   -> Translate x y $ Color (light blue) $ Circle 8 where (x,y) = a^.aPosition
  EArmor a  -> Translate x y $ Color red $ Circle 10 where (x,y) = a^.rPosition

  _ -> Blank

emptyInput = Input 0 0 False 0 0
emptyWorld = World
  [ EPlayer initialPlayer
  , EBullet (Bullet (30,30) (10,10) 100 10)
  , EWeapon (Weapon (10,20))
  , EAmmo   (Ammo (100,100) 20)
  , EArmor  (Armor (200,100) 30)
  ] emptyInput

main = play (InWindow "Lens MiniGame" (800, 600) (10, 10)) white 100 emptyWorld renderFun inputFun stepFun