//! Numerical agreement between our encoder states and the native Metal states.

/// Errors of `ours` against `reference`, both frame-major `[n_frames][n_state]`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Agreement {
    /// `max |ours - ref|`.
    pub max_abs: f64,
    /// `||ours - ref||₂ / ||ref||₂` over the whole row.
    pub rel_l2: f64,
    /// Smallest per-frame cosine similarity.
    pub min_cos: f64,
}

pub fn compare(ours: &[f32], reference: &[f32], n_state: usize) -> Agreement {
    assert_eq!(ours.len(), reference.len(), "state lengths differ");
    assert!(
        n_state > 0 && ours.len() % n_state == 0,
        "not a whole number of frames"
    );
    let mut max_abs = 0f64;
    let (mut diff2, mut ref2) = (0f64, 0f64);
    let mut min_cos = f64::INFINITY;
    for (a, b) in ours
        .chunks_exact(n_state)
        .zip(reference.chunks_exact(n_state))
    {
        let (mut dot, mut aa, mut bb) = (0f64, 0f64, 0f64);
        for (&x, &y) in a.iter().zip(b) {
            let (x, y) = (f64::from(x), f64::from(y));
            let d = x - y;
            max_abs = max_abs.max(d.abs());
            diff2 += d * d;
            ref2 += y * y;
            dot += x * y;
            aa += x * x;
            bb += y * y;
        }
        let cos = if aa == 0.0 && bb == 0.0 {
            1.0
        } else {
            dot / (aa.sqrt() * bb.sqrt())
        };
        min_cos = min_cos.min(cos);
    }
    if ours.iter().any(|v| !v.is_finite()) {
        return Agreement {
            max_abs: f64::NAN,
            rel_l2: f64::NAN,
            min_cos: f64::NAN,
        };
    }
    Agreement {
        max_abs,
        rel_l2: (diff2 / ref2).sqrt(),
        min_cos,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identical_rows_agree_exactly() {
        let a = [1.0f32, -2.0, 3.0, 0.5];
        let e = compare(&a, &a, 2);
        assert_eq!((e.max_abs, e.rel_l2), (0.0, 0.0));
        assert!((e.min_cos - 1.0).abs() < 1e-12);
    }

    #[test]
    fn measures_a_known_difference() {
        let r = [3.0f32, 4.0];
        let o = [3.0f32, 4.5];
        let e = compare(&o, &r, 2);
        assert!((e.max_abs - 0.5).abs() < 1e-12);
        assert!((e.rel_l2 - 0.1).abs() < 1e-12);
        assert!(e.min_cos < 1.0);
    }
}
