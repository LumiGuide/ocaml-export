{-|
Module      : OCaml.BuckleScript.Record
Description : Create OCaml data types from Haskell data types
Copyright   : Plow Technologies, 2017
License     : BSD3
Maintainer  : mchaver@gmail.com
Stability   : experimental

For a Haskell type with an instance of OCamlType, output the
OCaml type declaration.
-}

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module OCaml.BuckleScript.Record
  ( toOCamlTypeSourceWith
  ) where

-- base
import Control.Monad.Reader
import Data.List (nub, sort)
import Data.Maybe (catMaybes)
import Data.Typeable

-- containers
import qualified Data.Map.Strict as Map

-- ocaml-export
import OCaml.BuckleScript.Types
import OCaml.Internal.Common

-- text
import Data.Text (Text)
import qualified Data.Text as T

-- wl-pprint
import Text.PrettyPrint.Leijen.Text
  (Doc, (<+>), (<$$>), comma, indent, line, parens, space)

-- | Convert a 'Proxy a' into OCaml type source code.
toOCamlTypeSourceWith :: forall a. OCamlType a => Options -> a -> T.Text
toOCamlTypeSourceWith options a =
  case toOCamlType (Proxy :: Proxy a) of
    OCamlDatatype haskellTypeMetaData _ _ ->
      case Map.lookup haskellTypeMetaData (dependencies options) of
        Just ocamlTypeMetaData -> pprinter $ runReader (render (toOCamlType a)) (TypeMetaData (Just ocamlTypeMetaData) options)
        Nothing -> ""
    _ -> pprinter $ runReader (render (toOCamlType a)) (TypeMetaData Nothing options)

-- Internal functions to convert OCamlDatatype into BuckleScript source code.

-- | render a Haskell data type in OCaml
class HasType a where
  render :: a -> Reader TypeMetaData Doc

-- | render the rows of a record type
class HasRecordType a where
  renderRecord :: a -> Reader TypeMetaData Doc

-- | render a type as a reference, not its implementation details
class HasTypeRef a where
  renderRef :: a -> Reader TypeMetaData Doc

instance HasType OCamlDatatype where
  render datatype@(OCamlDatatype _mOCamlTypeDataType typeName constructor@(OCamlSumOfRecordConstructor _ (MultipleConstructors constructors))) = do
    -- For each constructor, if it is a record constructor, declare a type for that record
    -- before and separate from the main sum type.
    sumRecordsData <- catMaybes <$> sequence (renderSumRecord typeName <$> constructors)
    let sumRecords = msuffix (line <> line) (fst <$> sumRecordsData)
        newConstructors = replaceRecordConstructors (snd <$> sumRecordsData) <$> constructors
        typeParameters = renderTypeParameters constructor
    fnName <- renderRef datatype
    fnBody <- render (OCamlValueConstructor $ MultipleConstructors newConstructors)
    pure $ sumRecords <> ("type" <+> typeParameters <+> fnName <+> "=" <$$> indent 2 ("|" <+> fnBody))

  render datatype@(OCamlDatatype _ _ constructor@(OCamlValueConstructor (RecordConstructor _ _))) = do
    let typeParameters = renderTypeParameters constructor
    fnName <- renderRef datatype
    fnBody <- render constructor
    pure $ "type" <+> typeParameters <+> fnName <+> "=" <$$> indent 2 fnBody

  render (OCamlDatatype _ typeName constructor) = do
    let typeParameters = renderTypeParameters constructor
    let fnName = stext . textLowercaseFirst $ typeName
    fnBody <- render constructor
    pure $ "type" <+> typeParameters <+> fnName <+> "=" <$$> indent 2 ("|" <+> fnBody)

  render (OCamlPrimitive primitive) = renderRef primitive

instance HasTypeRef OCamlDatatype where
  renderRef (OCamlDatatype _ _ (OCamlValueConstructor (NamedConstructor _ (OCamlRefApp typRep values)))) = do
    dx <- renderRef values
    let name = stext . textLowercaseFirst . T.pack . show $ typeRepTyCon typRep
    mOCamlTypeMetaData <- asks topLevelOCamlTypeMetaData 
    case mOCamlTypeMetaData of
      Nothing -> pure $ (parensIfNotBlank dx) <+> name
      Just decOCamlTypeMetaData -> do
        ds <- asks (dependencies . userOptions)
        case Map.lookup (typeRepToHaskellTypeMetaData typRep) ds of
          Just parOCamlTypeMetaData -> do
            let prefix = stext $ mkModulePrefix decOCamlTypeMetaData parOCamlTypeMetaData
            pure $ (parensIfNotBlank dx) <+> prefix <> name
          Nothing -> error ("expected to find dependency:\n\n" ++ (show $ typeRepToHaskellTypeMetaData typRep) ++ "\n\nin\n\n" ++ show ds)

  renderRef datatype@(OCamlDatatype typeRef typeName _) = do
    if isTypeParameterRef datatype
    then
      pure . stext $ "'" <> textLowercaseFirst typeName
    else do
      mOCamlTypeMetaData <- asks topLevelOCamlTypeMetaData 
      case mOCamlTypeMetaData of
        Nothing -> pure . stext . textLowercaseFirst $ typeName

        Just decOCamlTypeMetaData -> do
          ds <- asks (dependencies . userOptions)
          case Map.lookup typeRef ds of
            Just parOCamlTypeMetaData -> do
              let prefix = stext $ mkModulePrefix decOCamlTypeMetaData parOCamlTypeMetaData
              pure $ prefix <> (stext . textLowercaseFirst $ typeName)
            Nothing -> error ("expected to find dependency:\n\n" ++ show typeRef ++ "\n\nin\n\n" ++ show ds)

  renderRef (OCamlPrimitive primitive) = renderRef primitive

instance HasTypeRef OCamlValue where
  renderRef (OCamlRefAppValues x y) = do
    dx <- render x
    dy <- render y
    pure $ dx <> comma <+> dy

  renderRef (OCamlRef _metaData primitive) = pure $ stext primitive
  renderRef (OCamlPrimitiveRef primitive) = renderRef primitive
  renderRef _ = pure ""
            
instance HasType OCamlConstructor where
  render (OCamlValueConstructor value) = render value
  render (OCamlSumOfRecordConstructor _ value) = render value
  render (OCamlEnumeratorConstructor constructors) =
    mintercalate (line <> "|" <> space) <$> sequence (render <$> constructors)

instance HasType ValueConstructor where
  -- record constructor
  render (RecordConstructor _ value) = do
    fields <- renderRecord value
    pure $ "{" <+> fields <$$> "}"

  -- enumerator constructor
  render (NamedConstructor constructorName (OCamlEmpty)) = do
    pure $ stext constructorName

  -- constructor with one or more values
  render (NamedConstructor constructorName value) = do
    types <- render value
    pure $ stext constructorName <+> "of" <+> types

  -- multiple constructors (sum type)
  render (MultipleConstructors constructors) = do
    mintercalate (line <> "|" <> space) <$> sequence (render <$> constructors)

instance HasType EnumeratorConstructor where
  render (EnumeratorConstructor name) = pure (stext name)
  
instance HasType OCamlValue where
  render ref@(OCamlRef typeRef name) = do
    mOCamlTypeMetaData <- asks topLevelOCamlTypeMetaData
    case mOCamlTypeMetaData of
      Nothing -> error $ "OCaml.BuckleScript.Record (HasType (OCamlDatatype typeRep name)) mOCamlTypeMetaData is Nothing:\n\n" ++ (show ref)
      Just ocamlTypeRef -> do
        ds <- asks (dependencies . userOptions)
        pure . stext $ appendModule ds ocamlTypeRef typeRef name

  render (OCamlRefApp typRep values) = do
    mOCamlTypeMetaData <- asks topLevelOCamlTypeMetaData
    case mOCamlTypeMetaData of
      Nothing -> error $ "OCaml.BuckleScript.Record (HasType (OCamlDatatype typeRep name)) mOCamlTypeMetaData is Nothing:\n\n"
      Just ocamlTypeRef -> do
        ds <- asks (dependencies . userOptions)
        dx <- render values
        pure $ (parensIfNotBlank dx) <+> (stext $ appendModule ds ocamlTypeRef (typeRepToHaskellTypeMetaData typRep) (T.pack . show $ typeRepTyCon typRep))

  render (OCamlTypeParameterRef name) = pure $ stext ("'" <> name)

  render (OCamlPrimitiveRef primitive) = ocamlRefParens primitive <$> renderRef primitive

  render (Values x y) = do
    dx <- render x
    dy <- render y
    pure $ dx <+> "*" <+> dy

  render (OCamlRefAppValues x y) = do
    dx <- render x
    dy <- render y
    pure $ dx <> comma <+> dy

  render (OCamlField name value) = do
    dv <- renderRecord value
    pure $ stext name <+> ":" <+> dv

  render OCamlEmpty = pure ""

instance HasRecordType OCamlValue where
  renderRecord (Values x y) = do
    dx <- renderRecord x
    dy <- renderRecord y
    pure $ dx <$$> ";" <+> dy

  renderRecord (OCamlPrimitiveRef primitive) = renderRef primitive
  renderRecord value = render value

instance HasTypeRef OCamlPrimitive where
  renderRef OBool   = pure "bool"
  renderRef OChar   = pure "string"
  renderRef ODate   = pure "Js_date.t"
  renderRef OFloat  = pure "float"
  renderRef OInt    = pure "int"
  renderRef OInt32  = pure "int32"
  renderRef OString = pure "string"
  renderRef OUnit   = pure "unit"

  renderRef (OList (OCamlPrimitive OChar)) = renderRef OString

  renderRef (OList datatype) = do
    dt <- renderRef datatype
    pure $ parens dt <+> "list"

  renderRef (OOption datatype) = do
    dt <- renderRef datatype
    pure $ parens dt <+> "option"

  renderRef (OEither l r) = do
    dl <- renderRef l
    dr <- renderRef r
    pure $ (parens $ dl <> comma <+> dr) <+> "Aeson.Compatibility.Either.t"

  renderRef (OTuple2 a b) = do
    da <- renderRef a
    db <- renderRef b
    pure . parens $ da <+> "*" <+> db

  renderRef (OTuple3 a b c) = do
    da <- renderRef a
    db <- renderRef b
    dc <- renderRef c
    pure . parens $ da <+> "*" <+> db <+> "*" <+> dc

  renderRef (OTuple4 a b c d) = do
    da <- renderRef a
    db <- renderRef b
    dc <- renderRef c
    dd <- renderRef d
    pure . parens $ da <+> "*" <+> db <+> "*" <+> dc <+> "*" <+> dd

  renderRef (OTuple5 a b c d e) = do
    da <- renderRef a
    db <- renderRef b
    dc <- renderRef c
    dd <- renderRef d
    de <- renderRef e
    pure . parens $ da <+> "*" <+> db <+> "*" <+> dc <+> "*" <+> dd <+> "*" <+> de

  renderRef (OTuple6 a b c d e f) = do
    da <- renderRef a
    db <- renderRef b
    dc <- renderRef c
    dd <- renderRef d
    de <- renderRef e
    df <- renderRef f
    pure . parens $ da <+> "*" <+> db <+> "*" <+> dc <+> "*" <+> dd <+> "*" <+> de <+> "*" <+> df

-- Util functions

-- | A Haskell Sum of Records needs to be transformed into OCaml record types
--   and a sum type. Replace RecordConstructor with NamedConstructor.
replaceRecordConstructors :: [(Text,ValueConstructor)] -> ValueConstructor -> ValueConstructor
replaceRecordConstructors newConstructors recordConstructor@(RecordConstructor oldName _) = 
  case length newRecordConstructor > 0 of
    False -> recordConstructor
    True  -> head newRecordConstructor
  where
    replace (oldName', (RecordConstructor newName _value)) =
      if oldName == oldName' then (Just $ NamedConstructor oldName' (OCamlRef (HaskellTypeMetaData "" "" "") newName)) else Nothing
    replace _ = Nothing
    newRecordConstructor = catMaybes $ replace <$> newConstructors

replaceRecordConstructors _ rc = rc

-- | Given a constructor, output a list of type parameters.
--   (Maybe a) -> 'a0 list -> ["'a0"]
--   (Either a b) -> 'a0 'a1 list -> ["'a0","'a1"]
renderTypeParameters :: OCamlConstructor -> Doc
renderTypeParameters constructor = mkDocList $ stext . (<>) "'" <$> sort (nub $ getTypeParameters constructor)

-- | For Haskell Sum of Records, create OCaml record types of each RecordConstructor
renderSumRecord :: Text -> ValueConstructor -> Reader TypeMetaData (Maybe (Doc,(Text,ValueConstructor)))
renderSumRecord typeName constructor@(RecordConstructor name value) = do
  let sumRecordName = typeName <> name
  functionBody <- render constructor
  pure $ Just (("type" <+> (stext (textLowercaseFirst sumRecordName)) <+> "=" <$$> indent 2 functionBody), (name, (RecordConstructor sumRecordName value)))
renderSumRecord _ _ = pure Nothing

-- | If this type comes from a different OCaml module, then add the appropriate module prefix
appendModule :: Map.Map HaskellTypeMetaData OCamlTypeMetaData -> OCamlTypeMetaData -> HaskellTypeMetaData -> Text -> Text
appendModule m o h name =
  case Map.lookup h m of
    Just parOCamlTypeMetaData -> 
      (mkModulePrefix o parOCamlTypeMetaData) <> (textLowercaseFirst name)
    -- in case of a Haskell sum of products, ocaml-export creates a definition for each product
    -- within the same file as the sum. These products will not be in the dependencies map.
    Nothing -> textLowercaseFirst name

-- | Puts parentheses around the doc of an OCaml ref if it contains spaces.
ocamlRefParens :: OCamlPrimitive -> Doc -> Doc
ocamlRefParens (OList (OCamlPrimitive OChar)) = id
ocamlRefParens (OList _) = parens
ocamlRefParens (OOption _) = parens
ocamlRefParens _ = id

parensIfNotBlank :: Doc -> Doc
parensIfNotBlank d = let dx = show d in if (length dx) > 0 && dx /= " " then parens d else d
