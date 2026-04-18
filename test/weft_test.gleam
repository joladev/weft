import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option
import gleam/otp/static_supervisor
import gleeunit
import pog
import weft

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn parse_filename_valid_test() {
  assert weft.parse_filename("20260414145350-v1_create_jobs_table.sql")
    == Ok(#(1, "create_jobs_table"))
}

pub fn parse_filename_no_sql_test() {
  let filename = "20260414145350-v1_create_jobs_table"
  assert weft.parse_filename(filename) == Error(weft.InvalidFilename(filename))
}

pub fn parse_filename_no_v_test() {
  let filename = "20260414145350-1_create_jobs_table.sql"
  assert weft.parse_filename(filename) == Error(weft.InvalidFilename(filename))
}

pub fn parse_filename_missing_underscore_test() {
  let filename = "20260414145350-v1create_jobs_table.sql"
  assert weft.parse_filename(filename) == Error(weft.InvalidFilename(filename))
}

pub fn parse_filename_non_numeric_version_test() {
  let filename = "20260414145350-vx_create_jobs_table.sql"
  assert weft.parse_filename(filename) == Error(weft.InvalidFilename(filename))
}

pub fn parse_markers_valid_test() {
  let content =
    "--- migration:up
CREATE TABLE foo (id bigint);
--- migration:down
DROP TABLE foo;
--- migration:end"

  assert weft.parse_markers("20260414145350-v1_create_jobs_table.sql", content)
    == Ok(#("CREATE TABLE foo (id bigint);", "DROP TABLE foo;"))
}

pub fn parse_markers_invalid_migration_up_test() {
  let content =
    "CREATE TABLE foo (id bigint);
--- migration:down
DROP TABLE foo;
--- migration:end"
  let filename = "20260414145350-v1_create_jobs_table.sql"

  assert weft.parse_markers(filename, content)
    == Error(weft.InvalidMigrationFormat(
      filename,
      "missing --- migration:up marker",
    ))
}

pub fn parse_markers_invalid_migration_down_test() {
  let content =
    "--- migration:up
CREATE TABLE foo (id bigint);
DROP TABLE foo;
--- migration:end"
  let filename = "20260414145350-v1_create_jobs_table.sql"

  assert weft.parse_markers(filename, content)
    == Error(weft.InvalidMigrationFormat(
      filename,
      "missing --- migration:down marker",
    ))
}

pub fn parse_markers_invalid_migration_end_test() {
  let content =
    "--- migration:up
CREATE TABLE foo (id bigint);
--- migration:down
DROP TABLE foo;"
  let filename = "20260414145350-v1_create_jobs_table.sql"

  assert weft.parse_markers(filename, content)
    == Error(weft.InvalidMigrationFormat(
      filename,
      "missing --- migration:end marker",
    ))
}

pub fn parse_migration_valid_test() {
  let filename = "20260414145350-v1_create_jobs_table.sql"
  let content =
    "--- migration:up
CREATE TABLE foo (id bigint);
--- migration:down
DROP TABLE foo;
--- migration:end"

  let version = 1
  let name = "create_jobs_table"
  let up_sql = "CREATE TABLE foo (id bigint);"
  let down_sql = "DROP TABLE foo;"

  assert weft.parse_migration(filename, content)
    == Ok(weft.Migration(version:, name:, filename:, up_sql:, down_sql:))
}

pub fn load_all_valid_test() {
  let assert Ok(migrations) = weft.load_all()
  let assert Ok(migration) = list.first(migrations)
  assert migration.version == 1
  assert migration.name == "create_jobs_table"
}

pub fn current_version_valid_test() {
  let connection = setup_migrations()
  let assert Ok(0) = weft.current_version(connection)
}

pub fn migrate_up_table_exists_test() {
  let connection = setup_migrations()

  let assert Ok(_) = weft.migrate_up(connection, 1)

  let decoder = {
    use result <- decode.field(0, decode.optional(decode.string))
    decode.success(result)
  }

  let assert Ok(_) =
    "SELECT to_regclass('weft_jobs')::text"
    |> pog.query()
    |> pog.returning(decoder)
    |> pog.execute(connection)
}

pub fn migrate_up_idempotent_test() {
  let connection = setup_migrations()

  let assert Ok(_) = weft.migrate_up(connection, 1)
  let assert Ok(1) = weft.current_version(connection)

  let assert Ok(_) = weft.migrate_up(connection, 1)
  let assert Ok(1) = weft.current_version(connection)
}

pub fn migrate_down_table_exists_test() {
  let connection = setup_migrations()

  let assert Ok(_) = weft.migrate_up(connection, 1)
  let assert Ok(1) = weft.current_version(connection)

  let decoder = {
    use result <- decode.field(0, decode.optional(decode.string))
    decode.success(result)
  }

  let assert Ok(pog.Returned(rows: [option.Some(_)], ..)) =
    "SELECT to_regclass('weft_jobs')::text"
    |> pog.query()
    |> pog.returning(decoder)
    |> pog.execute(connection)

  let assert Ok(_) = weft.migrate_down(connection, 0)
  let assert Ok(0) = weft.current_version(connection)

  let decoder = {
    use result <- decode.field(0, decode.optional(decode.string))
    decode.success(result)
  }

  let assert Ok(pog.Returned(rows: [option.None], ..)) =
    "SELECT to_regclass('weft_jobs')::text"
    |> pog.query()
    |> pog.returning(decoder)
    |> pog.execute(connection)
}

pub fn migrate_down_table_doesnt_exist_test() {
  let connection = setup_migrations()
  let assert Ok(_) = weft.migrate_down(connection, 0)
  let assert Ok(0) = weft.current_version(connection)
}

pub fn enqueue_succeeeds_test() {
  let connection = setup_migrations()
  let assert Ok(_) = weft.migrate_up(connection, 1)
  let assert Ok(_) = weft.enqueue(connection, "worker", json.object([]))
}

pub fn setup_migrations() {
  let name = process.new_name("test")
  let assert Ok(_) = start_application_supervisor(name)
  let connection = pog.named_connection(name)
  let assert Ok(_) = reset_migrations(connection)
  connection
}

pub fn reset_migrations(
  conn: pog.Connection,
) -> Result(pog.Returned(Nil), pog.QueryError) {
  let query_string = "DROP SCHEMA public CASCADE;"
  let query = pog.query(query_string)

  let assert Ok(_) = pog.execute(query, conn)

  let query_string = "CREATE SCHEMA public;"
  let query = pog.query(query_string)
  let assert Ok(_) = pog.execute(query, conn)
}

pub fn start_application_supervisor(pool_name: process.Name(pog.Message)) {
  let pool_child =
    pog.default_config(pool_name)
    |> pog.host("localhost")
    |> pog.database("weft_test")
    |> pog.pool_size(2)
    |> pog.supervised

  static_supervisor.new(static_supervisor.RestForOne)
  |> static_supervisor.add(pool_child)
  // |> static_supervisor.add(other)
  // |> static_supervisor.add(application)
  // |> static_supervisor.add(children)
  |> static_supervisor.start
}
