//! Compiles the C11 control (`c/vt_c.c`) into the crate: -O3, no -march/-mcpu, and
//! -ffp-contract=off so C never fuses a multiply-add the Rust code does not (see c/vt_c.c).

fn main() {
    println!("cargo:rerun-if-changed=c/vt_c.c");
    println!("cargo:rerun-if-changed=c/vt_c.h");
    cc::Build::new()
        .file("c/vt_c.c")
        .include("c")
        .std("c11")
        .opt_level(3)
        .flag("-ffp-contract=off")
        .flag("-fno-fast-math")
        .warnings(true)
        .extra_warnings(true)
        .compile("vt_c");
}
