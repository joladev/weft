import gleam/bool
import gleam/dynamic/decode
import gleam/erlang/application
import gleam/int
import gleam/io
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import pog
import simplifile

pub type MigrateError {
  DatabaseError(pog.QueryError)
  VersionParseError(String)
  LoadError(LoadError)
}

pub type LoadError {
  PrivDirNotFound
  InvalidFilename(name: String)
  InvalidMigrationFormat(filename: String, reason: String)
  FileReadError(filename: String, reason: String)
}

pub fn main() -> Nil {
  io.println("Hello from weft!")
}

pub type Migration {
  Migration(
    version: Int,
    name: String,
    filename: String,
    up_sql: String,
    down_sql: String,
  )
}

// Format <timestamp>-v<N>_<name>.sql
pub fn parse_filename(filename: String) -> Result(#(Int, String), LoadError) {
  let error = InvalidFilename(filename)

  use <- bool.guard(
    when: bool.negate(string.ends_with(filename, ".sql")),
    return: Error(error),
  )
  let skipped_ending = string.drop_end(filename, 4)
  use #(_, after_dash) <- result.try(
    skipped_ending
    |> string.split_once("-")
    |> result.replace_error(error),
  )
  case after_dash {
    "v" <> rest -> {
      use #(version_string, name) <- result.try(
        rest
        |> string.split_once("_")
        |> result.replace_error(error),
      )
      use version <- result.try(
        version_string
        |> int.parse()
        |> result.replace_error(error),
      )
      Ok(#(version, name))
    }
    _ -> Error(error)
  }
}

pub fn parse_markers(
  filename: String,
  content: String,
) -> Result(#(String, String), LoadError) {
  use #(_, after_up) <- result.try(
    content
    |> string.split_once("--- migration:up")
    |> result.replace_error(InvalidMigrationFormat(
      filename,
      "missing --- migration:up marker",
    )),
  )
  use #(up_sql, rest) <- result.try(
    after_up
    |> string.split_once("--- migration:down")
    |> result.replace_error(InvalidMigrationFormat(
      filename,
      "missing --- migration:down marker",
    )),
  )
  use #(down_sql, _) <- result.try(
    rest
    |> string.split_once("--- migration:end")
    |> result.replace_error(InvalidMigrationFormat(
      filename,
      "missing --- migration:end marker",
    )),
  )
  Ok(#(string.trim(up_sql), string.trim(down_sql)))
}

pub fn parse_migration(
  filename: String,
  content: String,
) -> Result(Migration, LoadError) {
  use #(version, name) <- result.try(parse_filename(filename))
  use #(up_sql, down_sql) <- result.try(parse_markers(filename, content))
  Ok(Migration(version:, name:, filename:, up_sql:, down_sql:))
}

pub fn load_all() -> Result(List(Migration), LoadError) {
  use directory <- result.try(
    "weft"
    |> application.priv_directory()
    |> result.replace_error(PrivDirNotFound),
  )
  let migrations_directory = directory <> "/migrations"
  use files <- result.try(
    migrations_directory
    |> simplifile.read_directory()
    |> result.map_error(fn(error) {
      FileReadError(migrations_directory, string.inspect(error))
    }),
  )
  let filtered = list.filter(files, string.ends_with(_, ".sql"))
  use migrations <- result.try(
    list.try_map(filtered, fn(filename) {
      let full_path = migrations_directory <> "/" <> filename
      use content <- result.try(
        full_path
        |> simplifile.read()
        |> result.map_error(fn(error) {
          FileReadError(full_path, string.inspect(error))
        }),
      )
      parse_migration(filename, content)
    }),
  )
  Ok(list.sort(migrations, fn(a, b) { int.compare(a.version, b.version) }))
}

pub fn current_version(conn: pog.Connection) -> Result(Int, MigrateError) {
  let query_string =
    "SELECT obj_description(to_regclass('weft_jobs'), 'pg_class')"
  let query = pog.query(query_string)

  let row_decoder = {
    use version <- decode.field(0, decode.optional(decode.string))
    decode.success(version)
  }

  use version <- result.try(
    query
    |> pog.returning(row_decoder)
    |> pog.execute(conn)
    |> result.map_error(fn(error) { DatabaseError(error) }),
  )

  case version.rows {
    [option.Some(raw_version)] -> {
      int.parse(raw_version)
      |> result.replace_error(VersionParseError(raw_version))
    }
    _ -> Ok(0)
  }
}

pub fn apply_up(
  conn: pog.Connection,
  migration: Migration,
) -> Result(Nil, MigrateError) {
  use _ <- result.try(
    conn
    |> pog.transaction(fn(conn) {
      use _ <- result.try(
        migration.up_sql
        |> pog.query()
        |> pog.execute(conn),
      )

      let query_string =
        "COMMENT ON TABLE weft_jobs IS '"
        <> int.to_string(migration.version)
        <> "';"

      query_string
      |> pog.query()
      |> pog.execute(conn)
    })
    |> result.map_error(fn(error) {
      case error {
        pog.TransactionQueryError(qe) -> DatabaseError(qe)
        pog.TransactionRolledBack(qr) -> DatabaseError(qr)
      }
    }),
  )

  Ok(Nil)
}

pub fn apply_down(
  conn: pog.Connection,
  migration: Migration,
) -> Result(Nil, MigrateError) {
  use _ <- result.try(
    conn
    |> pog.transaction(fn(conn) {
      use _ <- result.try(
        migration.down_sql
        |> pog.query()
        |> pog.execute(conn),
      )

      case migration.version > 1 {
        True -> {
          let query_string =
            "COMMENT ON TABLE weft_jobs IS '"
            <> int.to_string(migration.version)
            <> "';"

          query_string
          |> pog.query()
          |> pog.execute(conn)
          |> result.map(fn(_) { Nil })
        }
        False -> {
          Ok(Nil)
        }
      }
    })
    |> result.map_error(fn(error) {
      case error {
        pog.TransactionQueryError(qe) -> DatabaseError(qe)
        pog.TransactionRolledBack(qr) -> DatabaseError(qr)
      }
    }),
  )

  Ok(Nil)
}

pub fn migrate_up(
  conn: pog.Connection,
  target_version: Int,
) -> Result(Nil, MigrateError) {
  use migrations <- result.try(load_all() |> result.map_error(LoadError))
  use current_version <- result.try(current_version(conn))

  migrations
  |> list.filter(fn(migration) {
    migration.version > current_version && migration.version <= target_version
  })
  |> list.try_each(fn(migration) { apply_up(conn, migration) })
  |> result.map(fn(_) { Nil })
}

pub fn migrate_down(
  conn: pog.Connection,
  target_version: Int,
) -> Result(Nil, MigrateError) {
  use migrations <- result.try(load_all() |> result.map_error(LoadError))
  use current_version <- result.try(current_version(conn))

  migrations
  |> list.sort(fn(a, b) { int.compare(b.version, a.version) })
  |> list.filter(fn(migration) {
    migration.version <= current_version && migration.version > target_version
  })
  |> list.try_each(fn(migration) { apply_down(conn, migration) })
  |> result.map(fn(_) { Nil })
}
