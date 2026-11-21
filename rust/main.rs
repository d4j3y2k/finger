//! The same request handler used by the app, exposed on newline-delimited stdio.
use std::io::{self, BufRead, Write};

fn main() -> io::Result<()> {
    let stdin = io::stdin();
    let mut stdout = io::BufWriter::new(io::stdout().lock());
    for line in stdin.lock().lines() {
        writeln!(stdout, "{}", finger_core::request_json(&line?))?;
        stdout.flush()?;
    }
    Ok(())
}
