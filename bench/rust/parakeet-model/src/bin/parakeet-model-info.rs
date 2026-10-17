//! `parakeet-model-info <model.bin> [--verify]`
//!
//! Prints the hyperparameters, file sections, vocabulary special ids and every tensor record
//! of a parakeet ggml model. `--verify` additionally checks the file against the pinned size
//! and SHA-256 and re-derives the full architecture table (tensor set, extents, payload sizes,
//! counts per family) that `parakeet_model_load` expects. Exit status: 0 ok, 1 verification
//! failed, 2 usage or load error.

use std::collections::BTreeMap;
use std::io::{self, BufWriter, Write};
use std::path::PathBuf;
use std::process::ExitCode;

use parakeet_model::{HParam, Model, ggml_type_name, pin};

const USAGE: &str = "usage: parakeet-model-info <model.bin> [--verify]";

fn main() -> ExitCode {
    let mut path: Option<PathBuf> = None;
    let mut verify = false;
    for arg in std::env::args_os().skip(1) {
        if arg == "--verify" {
            verify = true;
        } else if arg == "-h" || arg == "--help" {
            println!("{USAGE}");
            return ExitCode::SUCCESS;
        } else if path.is_none() {
            path = Some(PathBuf::from(arg));
        } else {
            eprintln!("{USAGE}");
            return ExitCode::from(2);
        }
    }
    let Some(path) = path else {
        eprintln!("{USAGE}");
        return ExitCode::from(2);
    };
    let model = match Model::open(&path) {
        Ok(model) => model,
        Err(err) => {
            eprintln!("error: {err}");
            return ExitCode::from(2);
        }
    };
    let mut out = BufWriter::new(io::stdout().lock());
    let result = print_info(&mut out, &model).and_then(|()| {
        if verify {
            run_verify(&mut out, &model)
        } else {
            Ok(true)
        }
    });
    let flushed = out.flush();
    match (result, flushed) {
        (Ok(true), Ok(())) => ExitCode::SUCCESS,
        (Ok(false), Ok(())) => ExitCode::from(1),
        // A closed pipe (`| head`) is not an error worth reporting.
        (Err(err), _) | (_, Err(err)) if err.kind() == io::ErrorKind::BrokenPipe => {
            ExitCode::SUCCESS
        }
        (Err(err), _) | (_, Err(err)) => {
            eprintln!("error: {err}");
            ExitCode::from(2)
        }
    }
}

fn print_info(out: &mut impl Write, model: &Model) -> io::Result<()> {
    let hp = model.hparams();
    let layout = model.layout();
    writeln!(out, "file      {}", model.path().display())?;
    writeln!(out, "size      {} bytes", model.file_len())?;
    writeln!(
        out,
        "magic     {:#010x} (\"ggml\")",
        parakeet_model::GGML_FILE_MAGIC
    )?;

    writeln!(
        out,
        "hparams   (file order; validated like parakeet_validate_hparams)"
    )?;
    for which in [
        HParam::NVocab,
        HParam::NAudioCtx,
        HParam::NAudioState,
        HParam::NAudioHead,
        HParam::NAudioLayer,
        HParam::NMels,
    ] {
        writeln!(out, "  {:<24} = {}", which.name(), hp.get(which))?;
    }
    let wtype = hp.wtype().map_or("?", ggml_type_name);
    writeln!(
        out,
        "  {:<24} = {} (qntvr {}, wtype {wtype})",
        "ftype",
        hp.ftype,
        hp.qntvr()
    )?;
    for which in [
        HParam::NFft,
        HParam::SubsamplingFactor,
        HParam::NSubsamplingChannels,
        HParam::NConvKernel,
        HParam::NPredDim,
        HParam::NPredLayers,
        HParam::NTdtDurations,
        HParam::NMaxTokens,
    ] {
        writeln!(out, "  {:<24} = {}", which.name(), hp.get(which))?;
    }
    writeln!(
        out,
        "  {:<24} = {:e} (not stored: parakeet_hparams default)",
        "eps", hp.eps
    )?;
    for warning in model.hparam_warnings() {
        writeln!(out, "  native warning: {warning}")?;
    }

    let pre = model.preprocessor();
    writeln!(out, "sections  (byte offsets)")?;
    writeln!(
        out,
        "  hparams         @{:<10} 15 x i32",
        layout.hparams_offset
    )?;
    writeln!(
        out,
        "  mel filterbank  @{:<10} {} x {} f32 (n_mel x n_fb)",
        layout.filters_offset, pre.n_mels, pre.n_fb
    )?;
    writeln!(
        out,
        "  window          @{:<10} {} f32",
        layout.window_offset,
        pre.window.len()
    )?;
    writeln!(
        out,
        "  tdt durations   @{:<10} {:?}",
        layout.tdt_durations_offset,
        model.tdt_durations()
    )?;
    let vocab = model.vocab();
    writeln!(
        out,
        "  vocab           @{:<10} {} pieces",
        layout.vocab_offset,
        vocab.len()
    )?;
    writeln!(
        out,
        "  tensor records  @{:<10} {} records to EOF",
        layout.records_offset,
        model.tensor_count()
    )?;

    writeln!(out, "vocab")?;
    writeln!(
        out,
        "  pieces {} (+ blank), n_vocab {}, max piece {} bytes",
        vocab.len(),
        vocab.n_vocab(),
        vocab.max_piece_len()
    )?;
    for (label, id) in [
        ("blank", vocab.blank_id()),
        ("unk", vocab.unk_id()),
        ("bos", vocab.bos_id()),
        ("eos", vocab.eos_id()),
    ] {
        let piece = vocab
            .piece(id)
            .map(|p| String::from_utf8_lossy(p).into_owned())
            .unwrap_or_default();
        writeln!(out, "  {label:<5} id {id:<6} {piece:?}")?;
    }

    let variant = model.variant();
    let yes_no = |b: bool| if b { "present" } else { "absent" };
    writeln!(out, "variant")?;
    writeln!(
        out,
        "  encoder biases {}, batch-norm stats {}, speaker kernel {}, n_pre_enc_features {}",
        yes_no(variant.encoder_biases),
        yes_no(variant.batch_norm_stats),
        yes_no(variant.speaker_kernel),
        model.n_pre_enc_features()
    )?;

    let mut by_dtype: BTreeMap<&str, (usize, usize, usize)> = BTreeMap::new();
    for t in model.tensors() {
        let entry = by_dtype.entry(t.dtype.name()).or_default();
        entry.0 += 1;
        entry.1 += t.data.len();
        entry.2 += usize::from(t.file_offset % 2 == 0);
    }
    writeln!(out, "dtypes")?;
    for (name, (count, bytes, even)) in &by_dtype {
        writeln!(
            out,
            "  {name:<5} {count:>4} tensors {bytes:>12} bytes ({even} with 2-byte-aligned payload)"
        )?;
    }

    writeln!(out, "tensors   (file order)")?;
    writeln!(
        out,
        "  {:>4}  {:<5} {:<24} {:>11} {:>11}  name",
        "#", "dtype", "ne", "bytes", "offset"
    )?;
    for (i, t) in model.tensors().enumerate() {
        let ne = format!("{:?}", &t.ne[..t.n_dims.max(1)]);
        writeln!(
            out,
            "  {i:>4}  {:<5} {ne:<24} {:>11} {:>11}  {}",
            t.dtype.name(),
            t.data.len(),
            t.file_offset,
            t.name
        )?;
    }
    Ok(())
}

fn run_verify(out: &mut impl Write, model: &Model) -> io::Result<bool> {
    let mut ok = true;
    let mut check = |out: &mut dyn Write, label: &str, pass: bool, detail: String| {
        ok &= pass;
        writeln!(
            out,
            "  {label:<44} {:<6} {detail}",
            if pass { "ok" } else { "FAIL" }
        )
    };
    writeln!(out, "verify")?;

    let size = model.file_len() as u64;
    check(
        out,
        "size == pin",
        size == pin::SIZE,
        format!("{size} (pin {})", pin::SIZE),
    )?;
    let digest = pin::sha256_hex(model.bytes());
    check(
        out,
        "sha256 == pin",
        digest == pin::SHA256_HEX,
        format!("{digest} (pin {})", pin::SHA256_HEX),
    )?;

    writeln!(
        out,
        "  {:<44} {:>8} {:>8} {:>14}",
        "tensor family", "expected", "actual", "payload bytes"
    )?;
    let mut family_ok = true;
    for count in model.family_counts() {
        let pass = count.expected == count.actual;
        family_ok &= pass;
        writeln!(
            out,
            "  {:<44} {:>8} {:>8} {:>14} {}",
            count.family.label(),
            count.expected,
            count.actual,
            count.payload_bytes,
            if pass { "ok" } else { "FAIL" }
        )?;
    }
    let expected_total = model
        .family_counts()
        .iter()
        .map(|c| c.expected)
        .sum::<usize>();
    check(
        out,
        "record count == architecture",
        family_ok && expected_total == model.tensor_count(),
        format!(
            "{} records, {expected_total} expected",
            model.tensor_count()
        ),
    )?;

    let mismatches = model.architecture_mismatches();
    for m in &mismatches {
        writeln!(out, "    mismatch: {m}")?;
    }
    check(
        out,
        "names / ne / payload bytes == architecture",
        mismatches.is_empty(),
        format!("{} mismatches", mismatches.len()),
    )?;

    let records_end = model
        .tensors()
        .last()
        .map(|t| t.file_offset + t.data.len())
        .unwrap_or(model.layout().records_offset);
    check(
        out,
        "records tile the file to EOF",
        records_end == model.file_len(),
        format!("last payload ends at {records_end}"),
    )?;

    writeln!(out, "{}", if ok { "VERIFY OK" } else { "VERIFY FAILED" })?;
    Ok(ok)
}
