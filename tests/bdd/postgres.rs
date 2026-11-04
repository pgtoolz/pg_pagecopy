use std::net::TcpListener;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::OnceLock;
use std::time::Duration;
use tempfile::TempDir;
use tokio_postgres::{Client, NoTls, SimpleQueryMessage};

#[derive(Debug)]
pub struct PostgresPair {
    source: Postgres,
    target: Postgres,
    temp: TempDir,
}

impl PostgresPair {
    pub async fn start() -> Result<Self, String> {
        Self::start_with_checksums(false).await
    }

    pub async fn start_with_checksums(checksums: bool) -> Result<Self, String> {
        let major = default_major()?;
        Self::start_with_options(major, major, checksums, checksums).await
    }

    /// Same-major pair with independent checksum settings, for the BDD
    /// checksum-mismatch regressions that must run on every configured major.
    pub async fn start_with_mismatched_checksums(
        source_checksums: bool,
        target_checksums: bool,
    ) -> Result<Self, String> {
        let major = default_major()?;
        Self::start_with_options(major, major, source_checksums, target_checksums).await
    }

    pub async fn start_versions(
        source_major: u16,
        target_major: u16,
        checksums: bool,
    ) -> Result<Self, String> {
        Self::start_with_options(source_major, target_major, checksums, checksums).await
    }

    pub async fn start_with_options(
        source_major: u16,
        target_major: u16,
        source_checksums: bool,
        target_checksums: bool,
    ) -> Result<Self, String> {
        Self::start_with_config(
            source_major,
            target_major,
            source_checksums,
            target_checksums,
            None,
            None,
        )
        .await
    }

    pub async fn start_with_icu_locales(
        source_major: u16,
        target_major: u16,
        source_locale: &str,
        target_locale: &str,
    ) -> Result<Self, String> {
        Self::start_with_config(
            source_major,
            target_major,
            false,
            false,
            Some(source_locale),
            Some(target_locale),
        )
        .await
    }

    async fn start_with_config(
        source_major: u16,
        target_major: u16,
        source_checksums: bool,
        target_checksums: bool,
        source_locale: Option<&str>,
        target_locale: Option<&str>,
    ) -> Result<Self, String> {
        let temp = TempDir::new().map_err(|error| error.to_string())?;
        if is_root() {
            run(
                "chown",
                &["postgres:postgres", &temp.path().to_string_lossy()],
                false,
            )?;
        }
        let source = Postgres::start(
            temp.path(),
            "source",
            source_major,
            source_checksums,
            source_locale,
        )
        .await?;
        let target = Postgres::start(
            temp.path(),
            "target",
            target_major,
            target_checksums,
            target_locale,
        )
        .await?;
        Ok(Self {
            source,
            target,
            temp,
        })
    }

    pub fn source_port(&self) -> u16 {
        self.source.port
    }

    pub fn target_port(&self) -> u16 {
        self.target.port
    }

    fn port(&self, side: &str) -> u16 {
        match side {
            "source" => self.source.port,
            "target" => self.target.port,
            _ => panic!("unknown PostgreSQL side: {side}"),
        }
    }

    pub async fn execute(&self, side: &str, sql: &str) -> Result<(), String> {
        execute(self.port(side), sql).await
    }

    pub async fn query(&self, side: &str, sql: &str) -> Result<String, String> {
        query(self.port(side), sql).await
    }

    pub async fn create_tablespace(&self, side: &str) -> Result<(), String> {
        let path = self.temp.path().join("tablespace");
        std::fs::create_dir(&path).map_err(|error| error.to_string())?;
        if is_root() {
            run(
                "chown",
                &["postgres:postgres", &path.to_string_lossy()],
                false,
            )?;
        }
        self.execute(
            side,
            &format!(
                "CREATE TABLESPACE attach_space LOCATION '{}'",
                path.to_string_lossy()
            ),
        )
        .await
    }

    pub async fn verify_target_checksums(&mut self) -> Result<(), String> {
        self.target.stop_clean()?;
        let data = self.target.data.to_string_lossy().into_owned();
        let program = pg_program(self.target.major, "pg_checksums");
        let mut command = if is_root() {
            let mut command = Command::new("runuser");
            command.args(["-u", "postgres", "--", &program]);
            command
        } else {
            Command::new(&program)
        };
        let output = command
            .arg("--check")
            .arg("-D")
            .arg(&data)
            .output()
            .map_err(|error| format!("{program}: {error}"))?;
        self.target.restart().await?;
        if !output.status.success() {
            return Err(format!(
                "pg_checksums --check failed: {}{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            ));
        }
        Ok(())
    }

    pub fn source_log(&self) -> Result<String, String> {
        std::fs::read_to_string(&self.source.log).map_err(|error| error.to_string())
    }

    pub fn stop_source(&self) -> Result<(), String> {
        self.source.stop()
    }

    pub async fn crash_target(&self) -> Result<(), String> {
        self.target.crash()?;
        self.target.restart().await
    }

    pub fn crash_target_only(&self) -> Result<(), String> {
        self.target.crash()
    }

    pub async fn start_target(&self) -> Result<(), String> {
        self.target.restart().await
    }

    pub fn target_data_path(&self, relative: &str) -> PathBuf {
        if std::path::Path::new(relative).is_absolute() {
            PathBuf::from(relative)
        } else {
            self.target.data.join(relative)
        }
    }

    pub async fn cancel_target(&self, sql: &str, delay: Duration) -> Result<(), String> {
        cancel_execute(self.target.port, sql, CancelTrigger::Delay(delay)).await
    }

    /// Cancel a target statement only after the importer's test hook parks at
    /// the index-page milestone: heap, TOAST and at least one index page are
    /// already installed, so the cancellation can no longer land during
    /// preparation or race a completed import.
    pub async fn cancel_target_after_index_milestone(&self, sql: &str) -> Result<(), String> {
        cancel_execute(self.target.port, sql, CancelTrigger::IndexMilestone).await
    }

    pub async fn change_target_owner_during_import(&self, sql: &str) -> Result<(), String> {
        let (owner, owner_task) = connect(self.target.port).await?;
        owner
            .batch_execute("BEGIN; ALTER TABLE public.events OWNER TO postgres")
            .await
            .map_err(|error| error_detail(&error))?;
        let import_sql = format!("SET ROLE loader; {sql}");
        let import = execute(self.target.port, &import_sql);
        tokio::pin!(import);
        let deadline = std::time::Instant::now() + Duration::from_secs(30);
        loop {
            if std::time::Instant::now() >= deadline {
                let _ = owner.batch_execute("ROLLBACK").await;
                return Err("import did not wait for target relation lock".to_owned());
            }
            let waiting = owner.query_one(
                "SELECT count(*)::bigint FROM pg_locks \
                 WHERE relation = 'public.events'::regclass \
                   AND mode = 'AccessExclusiveLock' AND NOT granted",
                &[],
            );
            tokio::pin!(waiting);
            let count = tokio::select! {
                result = &mut import => {
                    let _ = owner.batch_execute("ROLLBACK").await;
                    return Err(format!("import finished before target lock wait: {result:?}"));
                }
                result = &mut waiting => result.map_err(|error| error_detail(&error))?,
            };
            if count.get::<_, i64>(0) == 1 {
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        owner
            .batch_execute("COMMIT")
            .await
            .map_err(|error| error_detail(&error))?;
        let result = tokio::time::timeout(Duration::from_secs(10), import)
            .await
            .map_err(|_| "import did not finish after ownership change".to_owned())?;
        drop(owner);
        let _ = owner_task.await;
        match result {
            Err(error) if error.contains("target table must be owned by the current user") => {
                Ok(())
            }
            other => Err(format!(
                "ownership race import returned unexpected result: {other:?}"
            )),
        }
    }
}

#[derive(Debug)]
struct Postgres {
    data: PathBuf,
    log: PathBuf,
    port: u16,
    major: u16,
}

impl Postgres {
    async fn start(
        parent: &Path,
        name: &str,
        major: u16,
        checksums: bool,
        icu_locale: Option<&str>,
    ) -> Result<Self, String> {
        let data = parent.join(name);
        let log = parent.join(format!("{name}.log"));
        let port = unused_port()?;
        let data_arg = data.to_string_lossy().into_owned();
        let mut initdb_args = vec![
            "-D",
            &data_arg,
            "--no-sync",
            "--auth=trust",
            "--username=postgres",
        ];
        if let Some(locale) = icu_locale {
            initdb_args.push("--locale-provider=icu");
            initdb_args.push("--icu-locale");
            initdb_args.push(locale);
        }
        if checksums {
            initdb_args.push("--data-checksums");
        }
        run(&pg_program(major, "initdb"), &initdb_args, true)?;
        if !checksums {
            // PG18 enables checksums by default; older versions report already disabled.
            let _ = run(
                &pg_program(major, "pg_checksums"),
                &["-D", &data_arg, "--disable"],
                true,
            );
        }
        let postgres = Self {
            data,
            log,
            port,
            major,
        };
        let socket = parent.to_string_lossy();
        let options = format!("-F -p {port} -k {socket} -c listen_addresses=127.0.0.1");
        run(
            &pg_program(major, "pg_ctl"),
            &[
                "-D",
                &postgres.data.to_string_lossy(),
                "-l",
                &postgres.log.to_string_lossy(),
                "-w",
                "-o",
                &options,
                "start",
            ],
            true,
        )?;
        postgres.wait_until_ready().await?;
        Ok(postgres)
    }

    fn stop(&self) -> Result<(), String> {
        run(
            &pg_program(self.major, "pg_ctl"),
            &[
                "-D",
                &self.data.to_string_lossy(),
                "-w",
                "-m",
                "immediate",
                "stop",
            ],
            true,
        )
    }

    /// Clean shutdown for offline tools (`pg_checksums`) that refuse an
    /// immediate-stop cluster.
    fn stop_clean(&self) -> Result<(), String> {
        run(
            &pg_program(self.major, "pg_ctl"),
            &[
                "-D",
                &self.data.to_string_lossy(),
                "-w",
                "-m",
                "fast",
                "stop",
            ],
            true,
        )
    }

    fn crash(&self) -> Result<(), String> {
        let pid = std::fs::read_to_string(self.data.join("postmaster.pid"))
            .map_err(|error| error.to_string())?
            .lines()
            .next()
            .unwrap_or_default()
            .to_string();
        run(
            &pg_program(self.major, "pg_ctl"),
            &["kill", "KILL", &pid],
            true,
        )?;
        // Wait for the postmaster to exit, then drop the stale lock file: a
        // killed postmaster cannot clean up, and PID reuse makes the next
        // start treat the file as a live server.
        let pid_path = format!("/proc/{pid}");
        for _ in 0..100 {
            if std::fs::metadata(&pid_path).is_err() {
                break;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        let _ = std::fs::remove_file(self.data.join("postmaster.pid"));
        // Same for the unix socket: killed postmasters leave both files behind.
        let socket_dir = self.data.parent().unwrap_or(&self.data).to_path_buf();
        let _ = std::fs::remove_file(socket_dir.join(format!(".s.PGSQL.{}.lock", self.port)));
        let _ = std::fs::remove_file(socket_dir.join(format!(".s.PGSQL.{}", self.port)));
        Ok(())
    }

    async fn restart(&self) -> Result<(), String> {
        let socket = self
            .data
            .parent()
            .unwrap_or(&self.data)
            .to_string_lossy()
            .into_owned();
        let options = format!(
            "-F -p {} -k {socket} -c listen_addresses=127.0.0.1",
            self.port
        );
        let data = self.data.to_string_lossy().into_owned();
        let log = self.log.to_string_lossy().into_owned();
        for attempt in 1..=3 {
            match run(
                &pg_program(self.major, "pg_ctl"),
                &[
                    "-D", &data, "-l", &log, "-w", "-t", "30", "-o", &options, "start",
                ],
                true,
            ) {
                Ok(()) => return self.wait_until_ready().await,
                // Orphaned postmaster children release shared memory asynchronously.
                Err(error) if attempt < 3 => {
                    eprintln!("target restart attempt {attempt} failed: {error}");
                    tokio::time::sleep(Duration::from_millis(500)).await;
                }
                Err(error) => return Err(error),
            }
        }
        unreachable!()
    }

    async fn wait_until_ready(&self) -> Result<(), String> {
        for _ in 0..100 {
            if query(self.port, "SELECT 1").await.as_deref() == Ok("1") {
                return Ok(());
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        Err(format!(
            "PostgreSQL on port {} did not become ready: {}",
            self.port,
            std::fs::read_to_string(&self.log).unwrap_or_default()
        ))
    }
}

impl Drop for Postgres {
    fn drop(&mut self) {
        if let Some(directory) = std::env::var_os("PG_PAGECOPY_LOG_DIR") {
            let directory = PathBuf::from(directory);
            let name = self
                .data
                .file_name()
                .and_then(|name| name.to_str())
                .unwrap_or("postgres");
            let destination = directory.join(format!("{name}-{}.log", self.port));
            if let Err(error) = std::fs::create_dir_all(&directory)
                .and_then(|()| std::fs::copy(&self.log, &destination).map(|_| ()))
                .and_then(|()| {
                    std::fs::set_permissions(&destination, std::fs::Permissions::from_mode(0o644))
                })
            {
                eprintln!("failed to preserve PostgreSQL log: {error}");
            }
        }
        let _ = self.stop();
        if std::thread::panicking() {
            eprintln!(
                "PostgreSQL log {}:\n{}",
                self.log.display(),
                std::fs::read_to_string(&self.log).unwrap_or_default()
            );
        }
    }
}

fn error_detail(error: &tokio_postgres::Error) -> String {
    error.as_db_error().map_or_else(
        || error.to_string(),
        |db| format!("{} {}: {}", db.severity(), db.code().code(), db.message()),
    )
}

async fn connect(port: u16) -> Result<(Client, tokio::task::JoinHandle<()>), String> {
    let dsn = format!("host=127.0.0.1 port={port} dbname=postgres user=postgres");
    let (client, connection) = tokio_postgres::connect(&dsn, NoTls)
        .await
        .map_err(|error| error.to_string())?;
    let task = tokio::spawn(async move {
        if let Err(error) = connection.await {
            eprintln!("PostgreSQL connection error: {error}");
        }
    });
    Ok((client, task))
}

/// What must be observed before a cancellation is delivered.
enum CancelTrigger {
    Delay(Duration),
    /// The importing backend published the test-hook milestone through
    /// `pg_stat_activity`: the chosen index page is installed and the import
    /// is parked there waiting for this very cancellation.
    IndexMilestone,
}

async fn wait_for_cancel_trigger(port: u16, trigger: &CancelTrigger) {
    match trigger {
        CancelTrigger::Delay(delay) => tokio::time::sleep(*delay).await,
        CancelTrigger::IndexMilestone => {
            let (client, task) = connect(port).await.expect("milestone poll connect failed");
            let deadline = std::time::Instant::now() + Duration::from_secs(180);
            loop {
                assert!(
                    std::time::Instant::now() < deadline,
                    "import never published the index-page hold milestone"
                );
                let seen = client
                    .simple_query(
                        "SELECT count(*)::text FROM pg_stat_activity \
                         WHERE application_name = 'pg_pagecopy index hold'",
                    )
                    .await;
                if let Ok(messages) = seen {
                    let parked = messages.iter().any(|message| {
                        matches!(message, SimpleQueryMessage::Row(row) if row.get(0) == Some("1"))
                    });
                    if parked {
                        break;
                    }
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
            drop(client);
            let _ = task.await;
        }
    }
}

async fn cancel_execute(port: u16, sql: &str, trigger: CancelTrigger) -> Result<(), String> {
    let (client, task) = connect(port).await?;
    let cancel = client.cancel_token();
    let result = {
        let execution = client.batch_execute(sql);
        tokio::pin!(execution);
        let wait = wait_for_cancel_trigger(port, &trigger);
        tokio::pin!(wait);
        tokio::select! {
            result = &mut execution => {
                return Err(format!("import finished before cancellation: {result:?}"));
            }
            () = &mut wait => {
                cancel.cancel_query(NoTls).await.map_err(|error| error.to_string())?;
                tokio::time::timeout(Duration::from_secs(30), execution)
                    .await
                    .map_err(|_| "cancelled import did not finish within 30 seconds".to_owned())?
            }
        }
    };
    drop(client);
    let _ = task.await;
    match result {
        Ok(()) => Err("cancelled import unexpectedly succeeded".to_string()),
        Err(error)
            if error
                .as_db_error()
                .is_some_and(|db| db.code().code() == "57014") =>
        {
            Ok(())
        }
        Err(error) => Err(format!(
            "unexpected cancellation error: {}",
            error_detail(&error)
        )),
    }
}

async fn execute(port: u16, sql: &str) -> Result<(), String> {
    let (client, task) = connect(port).await?;
    let result = client
        .batch_execute(sql)
        .await
        .map_err(|error| error_detail(&error));
    drop(client);
    let _ = task.await;
    result
}

async fn query(port: u16, sql: &str) -> Result<String, String> {
    let (client, task) = connect(port).await?;
    let result = async {
        let messages = client
            .simple_query(sql)
            .await
            .map_err(|error| error_detail(&error))?;
        let mut rows = Vec::new();
        for message in messages {
            if let SimpleQueryMessage::Row(row) = message {
                let values = (0..row.len())
                    .map(|column| row.get(column).unwrap_or("NULL"))
                    .collect::<Vec<_>>()
                    .join("|");
                rows.push(values);
            }
        }
        Ok(rows.join("\n"))
    }
    .await;
    drop(client);
    let _ = task.await;
    result
}

fn default_major() -> Result<u16, String> {
    parse_major(&std::env::var("PG_VERSION").unwrap_or_else(|_| "17".to_string()))
}

fn parse_major(version: &str) -> Result<u16, String> {
    version
        .split('.')
        .next()
        .unwrap_or_default()
        .parse()
        .map_err(|_| "PG_VERSION must start with a PostgreSQL major number".to_string())
}

fn pg_program(major: u16, program: &str) -> String {
    format!("/usr/lib/postgresql/{major}/bin/{program}")
}

fn unused_port() -> Result<u16, String> {
    TcpListener::bind("127.0.0.1:0")
        .map_err(|error| error.to_string())?
        .local_addr()
        .map(|address| address.port())
        .map_err(|error| error.to_string())
}

fn is_root() -> bool {
    static ROOT: OnceLock<bool> = OnceLock::new();
    *ROOT.get_or_init(|| {
        Command::new("id")
            .arg("-u")
            .output()
            .is_ok_and(|output| output.stdout == b"0\n")
    })
}

fn run(program: &str, args: &[&str], as_postgres: bool) -> Result<(), String> {
    let mut command = if as_postgres && is_root() {
        let mut command = Command::new("runuser");
        command.args(["-u", "postgres", "--", program]);
        command
    } else {
        Command::new(program)
    };
    let output = command
        .args(args)
        .output()
        .map_err(|error| format!("{program}: {error}"))?;
    if output.status.success() {
        Ok(())
    } else {
        Err(format!(
            "{program} failed with {}: {}",
            output.status,
            String::from_utf8_lossy(&output.stderr)
        ))
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn parses_major_and_official_docker_full_versions() {
        assert_eq!(super::parse_major("18"), Ok(18));
        assert_eq!(super::parse_major("18.6"), Ok(18));
        assert!(super::parse_major("not-a-version").is_err());
    }
}
