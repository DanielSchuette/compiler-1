{-# OPTIONS_GHC -Wall #-}
module Canonicalize.Pattern
  ( canonicalizeArgs
  , canonicalizeMatch
  , canonicalizeBindings
  , Binding(..)
  )
  where


import Control.Monad (zipWithM)
import qualified Data.Map.Strict as Map

import qualified AST.Expression.Canonical as Can
import qualified AST.Expression.Source as Src
import qualified AST.Expression.Valid as Valid
import qualified AST.Type as Type
import qualified Canonicalize.Environment as Env
import qualified Canonicalize.Environment.Dups as Dups
import qualified Data.Bag as Bag
import qualified Elm.Name as N
import qualified Reporting.Annotation as A
import qualified Reporting.Error.Canonicalize as Error
import qualified Reporting.Region as R
import qualified Reporting.Result as Result
import qualified Reporting.Warning as Warning



-- RESULTS


type Result i =
  Result.Result i Warning.Warning Error.Error



-- CANONICALIZE ARGS


canonicalizeArgs :: Env.Env -> [Src.Pattern] -> Result () Can.Args
canonicalizeArgs env patterns =
  case zipWithM (canonicalizeArg env) patterns [ 0 .. length patterns ] of
    Result.Result bag warnings (Result.Ok args) ->
      do  let toError name () () = Error.DuplicateArg name
          destructors <- Dups.detect toError (Bag.toList bag)
          Result.Result () warnings $ Result.Ok $
            Can.Args args destructors

    Result.Result _ warnings (Result.Err err) ->
      Result.Result () warnings (Result.Err err)


canonicalizeArg :: Env.Env -> Src.Pattern -> Int -> Result Bag Can.Arg
canonicalizeArg env pattern index =
  Can.Arg index <$> canonicalize env (Can.DRoot index) pattern



-- CANONICALIZE MATCH


canonicalizeMatch :: Env.Env -> Src.Pattern -> Result () Can.Match
canonicalizeMatch env pattern =
  case canonicalize env (Can.DRoot 0) pattern of
    Result.Result bag warnings (Result.Ok cpattern) ->
      do  let toError name () () = Error.DuplicateArg name
          destructors <- Dups.detect toError (Bag.toList bag)
          Result.Result () warnings $ Result.Ok $
            Can.Match cpattern destructors

    Result.Result _ warnings (Result.Err err) ->
      Result.Result () warnings (Result.Err err)



-- CANONICALIZE BINDINGS


data Binding
  = Define R.Region Int (A.Located N.Name) [Src.Pattern] Valid.Expr (Maybe Type.Raw)
  | Destruct R.Region Int Can.Match Valid.Expr


canonicalizeBindings :: Env.Env -> [Valid.Def] -> Result () ( [Binding], Map.Map N.Name (A.Located Int) )
canonicalizeBindings env defs =
  case zipWithM (canonicalizeBinding env) defs [ 0 .. length defs ] of
    Result.Result bag warnings (Result.Ok cdefs) ->
      do  let toError name () () = Error.DuplicateBindingName name
          nodes <- Dups.detect toError (Bag.toList bag)
          Result.Result () warnings (Result.Ok (cdefs, nodes))

    Result.Result _ warnings (Result.Err err) ->
      Result.Result () warnings (Result.Err err)


type KeyBag =
  Bag.Bag ( N.Name, [Dups.Info () (A.Located Int)] )


canonicalizeBinding :: Env.Env -> Valid.Def -> Int -> Result KeyBag Binding
canonicalizeBinding env def index =
  case def of
    Valid.Define region aname@(A.A reg name) args body maybeType ->
      let info = Dups.info name reg () (A.A region index) in
      Result.accumulate (Bag.one info) $
        Define region index aname args body maybeType

    Valid.Destruct region pattern body ->
      case canonicalize env (Can.DRoot 0) pattern of
        Result.Result bag warnings (Result.Ok cpattern) ->
          do  let toError name () () = Error.DuplicateBindingName name
              destructors <- Result.untracked (Dups.detect toError (Bag.toList bag))
              Result.Result (toKeyBag index bag) warnings $ Result.Ok $
                Destruct region index (Can.Match cpattern destructors) body

        Result.Result bag warnings (Result.Err err) ->
          Result.Result (toKeyBag index bag) warnings (Result.Err err)


toKeyBag :: Int -> Bag -> KeyBag
toKeyBag index bag =
  let
    redoInfo (Dups.Info region () _) =
      Dups.Info region () (A.A region index)

    replaceWithIndex ( name, infos ) =
      ( name, map redoInfo infos )
  in
  Bag.map replaceWithIndex bag



-- CANONICALIZE


type Bag =
  Bag.Bag (N.Name, [Dups.Info () (A.Located Can.Destructor)])


canonicalize :: Env.Env -> Can.Destructor -> Src.Pattern -> Result Bag Can.Pattern
canonicalize env destructor (A.A region pattern) =
  A.A region <$>
  case pattern of
    Src.PAnything ->
      Result.ok Can.PAnything

    Src.PVar name ->
      Result.accumulate
        (Bag.one (Dups.info name region () (A.A region destructor)))
        (Can.PVar name)

    Src.PRecord fields ->
      let
        fieldToInfo (A.A reg name) =
          Dups.info name reg () (A.A reg (Can.DField name destructor))
      in
      Result.accumulate
        (Bag.fromList fieldToInfo fields)
        (Can.PRecord (map A.drop fields))

    Src.PUnit ->
      Result.ok Can.PUnit

    Src.PTuple a b cs ->
      Can.PTuple
        <$> canonicalize env (Can.DIndex 0 destructor) a
        <*> canonicalize env (Can.DIndex 1 destructor) b
        <*> canonicalizeTuple region env destructor cs

    Src.PCtor nameRegion maybePrefix name patterns ->
      let
        ctorArg ptrn index =
          canonicalize env (Can.DIndex index destructor) ptrn
      in
      Can.PCtor
        <$> Env.findPattern nameRegion env maybePrefix name (length patterns)
        <*> pure name
        <*> zipWithM ctorArg patterns [ 0 .. length patterns ]

    Src.PList patterns ->
      Can.PList <$> canonicalizeList env destructor patterns

    Src.PCons first rest ->
      Can.PCons
        <$> canonicalize env (Can.DIndex 0 destructor) first
        <*> canonicalize env (Can.DIndex 1 destructor) rest

    Src.PAlias ptrn (A.A reg name) ->
      do  cpattern <- canonicalize env destructor ptrn
          let info = Dups.info name reg () (A.A reg destructor)
          Result.accumulate (Bag.one info) (Can.PAlias cpattern name)

    Src.PLiteral lit ->
      Result.ok (Can.PLiteral lit)


canonicalizeTuple :: R.Region -> Env.Env -> Can.Destructor -> [Src.Pattern] -> Result Bag (Maybe Can.Pattern)
canonicalizeTuple tupleRegion env destructor extras =
  case extras of
    [] ->
      Result.ok Nothing

    [three] ->
      Just <$> canonicalize env (Can.DIndex 2 destructor) three

    _ : others ->
      let (A.A r1 _, A.A r2 _) = (head others, last others) in
      Result.throw tupleRegion (Error.TupleLargerThanThree (R.merge r1 r2))


canonicalizeList :: Env.Env -> Can.Destructor -> [Src.Pattern] -> Result Bag [Can.Pattern]
canonicalizeList env destructor list =
  case list of
    [] ->
      Result.ok []

    pattern : otherPatterns ->
      (:)
        <$> canonicalize env (Can.DIndex 0 destructor) pattern
        <*> canonicalizeList env (Can.DIndex 1 destructor) otherPatterns
