//! The Seams agent's dumps: `.build/rust-bench/dumps/<corpus>/{index.jsonl, <n>.mel.f32, <n>.enc.f32}`.

use std::fs;
use std::path::{Path, PathBuf};

use crate::json;

#[derive(Clone, Debug)]
pub struct Row {
    pub id: String,
    pub audio_s: f64,
    pub n_mel_frames: usize,
    pub n_mels: usize,
    pub n_enc_frames: usize,
    pub n_state: usize,
    /// File name of the mel, relative to the corpus directory.
    pub mel_file: String,
    /// File name of the native encoder states, relative to the corpus directory.
    pub enc_file: String,
}

#[derive(Clone, Debug)]
pub struct Corpus {
    /// Directory name, e.g. `general96`.
    pub name: String,
    pub dir: PathBuf,
    pub rows: Vec<Row>,
}

impl Corpus {
    pub fn load(dir: &Path) -> Result<Corpus, String> {
        let index = dir.join("index.jsonl");
        let text = fs::read_to_string(&index).map_err(|e| format!("{}: {e}", index.display()))?;
        let mut rows = Vec::new();
        for (n, line) in text
            .lines()
            .enumerate()
            .filter(|(_, l)| !l.trim().is_empty())
        {
            let where_ = format!("{}:{}", index.display(), n + 1);
            let v = json::parse(line).map_err(|e| format!("{where_}: {e}"))?;
            let s = |k: &str| {
                v.get(k)
                    .and_then(json::Value::as_str)
                    .map(str::to_owned)
                    .ok_or(format!("{where_}: missing {k}"))
            };
            let u = |k: &str| {
                v.get(k)
                    .and_then(json::Value::as_usize)
                    .ok_or(format!("{where_}: missing {k}"))
            };
            rows.push(Row {
                id: s("id")?,
                audio_s: v
                    .get("audio_s")
                    .and_then(json::Value::as_f64)
                    .ok_or(format!("{where_}: missing audio_s"))?,
                n_mel_frames: u("n_mel_frames")?,
                n_mels: u("n_mels")?,
                n_enc_frames: u("n_enc_frames")?,
                n_state: u("n_state")?,
                mel_file: s("mel_file")?,
                enc_file: s("enc_file")?,
            });
        }
        let name = dir
            .file_name()
            .and_then(|n| n.to_str())
            .map(str::to_owned)
            .ok_or_else(|| format!("{}: no directory name", dir.display()))?;
        Ok(Corpus {
            name,
            dir: dir.to_path_buf(),
            rows,
        })
    }

    /// `dir` itself when it holds `index.jsonl`, else every child directory that does.
    pub fn discover(dir: &Path) -> Result<Vec<Corpus>, String> {
        if dir.join("index.jsonl").is_file() {
            return Ok(vec![Corpus::load(dir)?]);
        }
        let mut dirs: Vec<PathBuf> = fs::read_dir(dir)
            .map_err(|e| format!("{}: {e}", dir.display()))?
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.join("index.jsonl").is_file())
            .collect();
        dirs.sort();
        if dirs.is_empty() {
            return Err(format!(
                "{}: no index.jsonl here or in a child directory",
                dir.display()
            ));
        }
        dirs.iter().map(|d| Corpus::load(d)).collect()
    }

    pub fn mel(&self, row: &Row) -> Result<Vec<f32>, String> {
        read_f32(&self.dir.join(&row.mel_file), row.n_mel_frames * row.n_mels)
    }

    pub fn enc(&self, row: &Row) -> Result<Vec<f32>, String> {
        read_f32(
            &self.dir.join(&row.enc_file),
            row.n_enc_frames * row.n_state,
        )
    }
}

pub fn read_f32(path: &Path, count: usize) -> Result<Vec<f32>, String> {
    let bytes = fs::read(path).map_err(|e| format!("{}: {e}", path.display()))?;
    if bytes.len() != count * 4 {
        return Err(format!(
            "{}: {} bytes, expected {}",
            path.display(),
            bytes.len(),
            count * 4
        ));
    }
    Ok(bytes
        .chunks_exact(4)
        .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
        .collect())
}

pub fn f32_bytes(values: &[f32]) -> Vec<u8> {
    values.iter().flat_map(|v| v.to_le_bytes()).collect()
}
