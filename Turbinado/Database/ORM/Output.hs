module Database.HDBC.Generator where
import qualified Data.Char
import Control.Monad
import Data.Dynamic
import Data.List
import Database.HDBC
import System.Directory

type TableName = String
type ParentName = String
type TypeName = String
type PrimaryKeyColumnNames = [String]
type PrimaryKeyTypeNames = [String]

data TableSpec = TableSpec {
                    tableName :: String,
                    primaryKey :: (PrimaryKeyColumnNames, PrimaryKeyTypeNames),
                    columnDescriptions :: [(String, SqlColDesc)]
                    }

generateModels conn parentName = 
  do writeFile "Bases/ModelBase.hs" generateModelBase
     mapM (\t -> let typeName = (capitalizeName t)
                     fullName = typeName ++ "Model" in
                 do desc <- describeTable conn t
                    writeFile ("Bases/" ++ fullName ++ "Base.hs") (generateModel parentName typeName (TableSpec t (getPrimaryKeysFromDesc desc) desc))
                    doesFileExist (fullName ++ ".hs") >>= (\e -> when (not e) (writeFile (fullName++".hs") (generateModelFile parentName typeName) ) ) )
          =<< (getTables conn)

getPrimaryKeysFromDesc:: [(String, SqlColDesc)] -> (PrimaryKeyColumnNames, PrimaryKeyTypeNames)
getPrimaryKeysFromDesc desc =
  worker ([],[]) desc
    where worker (c,t) [] = (c,t)
          worker (c,t) (d:ds) = worker (if ((colIsPrimaryKey $ snd d) == True) then (c++[fst d], t++[getHaskellTypeString $ colType $ snd d]) else (c,t)) ds

generateModelFile parentName modelName =
  let fullName = (if (length parentName > 0) then parentName ++ "." else "") ++ modelName ++ "Model"
  in unlines $
  ["module " ++ fullName
  ,"  ( module " ++ fullName
  ,"  , module Bases." ++ fullName ++ "Base "
  ,"  ) where"
  ,"import Bases." ++ fullName ++ "Base"
  ]

generateModelBase :: String
generateModelBase = unlines $
  ["{- DO NOT EDIT THIS FILE"
  ,"   THIS FILE IS AUTOMAGICALLY GENERATED AND YOUR CHANGES WILL BE EATEN BY THE GENERATOR OVERLORD -}"
  ,""
  ,"module ModelBase ("
  ,"  module ModelBase,"
  ,"  module Control.Exception,"
  ,"  module Database.HDBC,"
  ,"  module Data.Int"
  ,") where"
  ,""
  ,"import Control.Exception"
  ,"import Database.HDBC"
  ,"import Data.Int"
  ,""
  ,"{- Using phantom types here -}"
  ,"class DatabaseModel m where"
  ,"  tableName :: m -> String"
  ,""
  ,"type SelectString = String"
  ,"type SelectParams = [SqlValue]"
  ,""
  ,"class (DatabaseModel model) =>"
  ,"        HasFindByPrimaryKey model primaryKey | model -> primaryKey where"
  ,"    find :: IConnection conn => conn -> primaryKey -> IO model"
  ,""
  ,"class (DatabaseModel model) =>"
  ,"        HasFinders model where"
  ,"        findAll   :: IConnection conn => conn -> IO [model]"
  ,"        findAllBy :: IConnection conn => conn -> SelectString -> SelectParams -> IO [model]"
  ,"        findOneBy :: IConnection conn => conn -> SelectString -> SelectParams -> IO model"
  ,""
  ]
{-------------------------------------------------------------------------}
generateModel ::  ParentName -> 
                  TypeName -> 
                  TableSpec -> 
                  String
generateModel parentName typeName tspec = 
  let cleanParentName = if (length parentName > 0) then parentName ++ "." else ""
  in unlines $
  ["{- DO NOT EDIT THIS FILE"
  ,"   THIS FILE IS AUTOMAGICALLY GENERATED AND YOUR CHANGES WILL BE EATEN BY THE GENERATOR OVERLORD"
  ,""
  ,"   All changes should go into the Model file (e.g. ExampleModel.hs) and"
  ,"   not into the base file (e.g. ExampleModelBase.hs) -}"
  ,""
  ,"module " ++ cleanParentName ++ typeName ++ "ModelBase ( "
  ," module Bases." ++ cleanParentName ++ typeName ++ "ModelBase, "
  ," module " ++ cleanParentName ++ "ModelBase) where"
  , ""
  , "import Bases." ++ cleanParentName ++ "ModelBase"
  , ""
  , "data " ++ typeName ++ " = " ++ typeName ++ " {"
  ] ++
  addCommas (map columnToFieldLabel (columnDescriptions tspec)) ++
  [ "    } deriving (Eq, Show)"
  , ""
  , "instance DatabaseModel " ++ typeName ++ " where"
  , "    tableName _ = \"" ++ tableName tspec ++ "\""
  , ""
  ] ++
  generateFindByPrimaryKey typeName tspec ++
  generateFinders typeName tspec

{-------------------------------------------------------------------------}
columnToFieldLabel :: (String, SqlColDesc) -> String
columnToFieldLabel (name, desc) =
  "    " ++ partiallyCapitalizeName name  ++ " :: " ++ 
  (if ((colNullable desc) == Just True) then "Maybe " else "") ++
  getHaskellTypeString (colType desc)

{-------------------------------------------------------------------------}
generateFindByPrimaryKey :: TypeName -> TableSpec -> [String]
generateFindByPrimaryKey typeName tspec =
  case (length $ fst $ primaryKey tspec) of
    0 -> [""]
    _ -> ["instance HasFindByPrimaryKey " ++ typeName ++ " " ++ " (" ++ unwords (intersperse "," (snd $ primaryKey tspec)) ++ ") " ++ " where"
         ,"    find conn pk@(" ++ (concat $ intersperse ", " $ map (\i -> "pk"++(show i)) [1..(length $ fst $ primaryKey tspec)]) ++ ") = do"
         ,"        res <- quickQuery' conn (\"SELECT * FROM " ++ tableName tspec ++ " WHERE (" ++ generatePrimaryKeyWhere (fst $ primaryKey tspec) ++ "++ \")\") []"
         ,"        case res of"
         ,"          [] -> throwDyn $ SqlError"
         ,"                           {seState = \"\","
         ,"                            seNativeError = (-1),"
         ,"                            seErrorMsg = \"No record found when finding by Primary Key:" ++ (tableName tspec) ++ " : \" ++ (show pk)"
         ,"                           }"
         ,"          r:[] -> return $ " ++ (generateConstructor typeName tspec)
         ,"          _ -> throwDyn $ SqlError"
         ,"                           {seState = \"\","
         ,"                            seNativeError = (-1),"
         ,"                            seErrorMsg = \"Too many records found when finding by Primary Key:" ++ (tableName tspec) ++ " : \" ++ (show pk)"
         ,"                           }"
         ]

generateFinders :: TypeName -> TableSpec -> [String]
generateFinders typeName tspec =
    ["instance HasFinders " ++ typeName ++ " where"
    ,"    findAll conn = do"
    ,"        res <- quickQuery' conn \"SELECT * FROM " ++ tableName tspec ++ "\" []"
    ,"        return $ map (\\r -> " ++ generateConstructor typeName tspec ++ ") res"
    ,"    findAllBy conn ss sp = do"
    ,"        res <- quickQuery' conn (\"SELECT * FROM " ++ tableName tspec ++ " WHERE (\" ++ ss ++ \") \")  sp"
    ,"        return $ map (\\r -> " ++ generateConstructor typeName tspec ++ ") res"
    ,"    findOneBy conn ss sp = do"
    ,"        res <- quickQuery' conn (\"SELECT * FROM " ++ tableName tspec ++ " WHERE (\" ++ ss ++ \") LIMIT 1\")  sp"
    ,"        return $ (\\r -> " ++ generateConstructor typeName tspec ++ ") (head res)"
     ]

{-----------------------------------------------------------------------}
generatePrimaryKeyWhere cnames = 
  unwords $
    intersperse "++ \" AND \" ++ \"" $
      map (\(c,i) -> c ++ " = \" ++ (show pk" ++ (show i) ++ ")") (zip cnames [1..])

generateConstructor typeName tspec =
  typeName ++ " " ++ (unwords $
  map (\i -> "(fromSql (r !! " ++ (show i) ++ "))") [0..((length $ columnDescriptions tspec)-1)])


{-------------------------------------------------------------------------
 -  Utility functions                                                    -
 -------------------------------------------------------------------------}
addCommas (s:[]) = [s]
addCommas (s:ss) = (s ++ ",") : (addCommas ss)

getHaskellTypeString :: SqlTypeId -> String
getHaskellTypeString    SqlCharT = "String"
getHaskellTypeString    SqlVarCharT = "String"
getHaskellTypeString    SqlLongVarCharT = "String"
getHaskellTypeString    SqlWCharT = "String"
getHaskellTypeString    SqlWVarCharT = "String"
getHaskellTypeString    SqlWLongVarCharT = "String"
getHaskellTypeString    SqlDecimalT = "Rational"
getHaskellTypeString    SqlNumericT = "Rational"
getHaskellTypeString    SqlSmallIntT ="Int32"
getHaskellTypeString    SqlIntegerT = "Int32"
getHaskellTypeString    SqlRealT = "Rational"
getHaskellTypeString    SqlFloatT = "Float"
getHaskellTypeString    SqlDoubleT = "Double"
getHaskellTypeString    SqlTinyIntT = "Int32"
getHaskellTypeString    SqlBigIntT = "Int64"
getHaskellTypeString    SqlDateT = "UTCTime"
getHaskellTypeString    SqlTimeT = "UTCTime"
getHaskellTypeString    SqlTimestampT = "UTCTime"
getHaskellTypeString    SqlUTCDateTimeT = "UTCTime"
getHaskellTypeString    SqlUTCTimeT = "UTCTime"
getHaskellTypeString    _ = error "Don't know how to translate this SqlTypeId to a SqlValue"


type SelectParameters = String

class TableType a where
  find   :: (IConnection conn) => conn -> Int -> a
  findBy :: (IConnection conn) => conn -> SelectParameters -> [a]

{-  Converts "column_name" to "ColumnName"
 -}
capitalizeName colname =
    concat $
      map (\(s:ss) -> (Data.Char.toUpper s) : ss) $
        words $
          map (\c -> if (c=='_') then ' ' else c) colname


partiallyCapitalizeName colname =
  (\(s:ss) -> (Data.Char.toLower s) : ss) $
   capitalizeName colname 

{-  If a column ends with "_id" then it's a foreign key
 -}
isForeignKey colname =
  drop (length colname - 3) colname == "_id"


{-
PostgreSQL query to get Primary Keys:
SELECT pg_attribute.attname 
  FROM pg_class 
    JOIN pg_namespace ON pg_namespace.oid=pg_class.relnamespace AND pg_namespace.nspname NOT LIKE 'pg_%' AND pg_class.relname like 'abba%' 
    JOIN pg_attribute ON pg_attribute.attrelid=pg_class.oid AND pg_attribute.attisdropped='f' 
    JOIN pg_index ON pg_index.indrelid=pg_class.oid AND pg_index.indisprimary='t' AND ( pg_index.indkey[0]=pg_attribute.attnum OR pg_inde
x.indkey[1]=pg_attribute.attnum OR pg_index.indkey[2]=pg_attribute.attnum OR pg_index.indkey[3]=pg_attribute.attnum OR pg_index.indkey[4]=pg_attribute.attnum OR pg_index.indkey[5]=pg_attribute.attnum OR pg_index.indkey[6]=pg_attribute.attnum OR pg_index.indkey[7]=pg_attribute.attnum OR pg_index.indkey[8]=pg_attribute.attnum OR pg_index.indkey[9]=pg_attribute.attnum ) 
  ORDER BY pg_namespace.nspname, pg_class.relname,pg_attribute.attname;
-}
