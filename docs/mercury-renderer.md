# Procedural mercury renderer

This document is the durable design record for Voiceour's recording island. It captures the physical model, geometry, optics, display mapping, performance work, rejected alternatives, and measured gates behind the implementation introduced by commits `5be9404` and `f9ac3ca` (2026-08-29).

It is a technical appendix, not a second product specification. [README.md](../README.md#product-contract) states what the island does for the user, and [README.md](../README.md#architecture) and [AGENTS.md](../AGENTS.md) state the binding UI, runtime, and harness invariants it satisfies. This file explains how the renderer meets them and why each alternative was rejected.

The implementation is physically motivated rather than a general fluid solver. It uses exact solutions where they buy determinism or stability, measured calibration where the visual target is product-specific, and bounded approximations where dense oracle tests prove that the displayed result cannot move by more than one 8-bit code value.

The island is also not Apple's system Liquid Glass. It is a private, CPU-rasterized liquid-metal organism rendered into one `CGImage`. It samples no desktop pixels, adds no screen-capture permission, and uses no authored highlight, rim, gradient, glyph, or moving light.

## Renderer contract

The renderer holds these properties; the tests and hard gates under [Measured gates](#measured-gates) verify the measurable ones:

- One procedural body conveys warming, listening, speaking, processing, copy-only delivery, paste failure, and error.
- `MercuryField` is the sole silhouette for raster coverage, drag hit-testing, and cursor routing.
- The body moves; its generated room does not. Static geometry must produce byte-identical reflections indefinitely.
- The visible material is polished liquid mercury: structured dark and bright bands, subtle room colour, and grazing reflectance—not a white pill.
- Physics advances in exact `1/120 s` steps. Presentation follows the display containing the panel, capped at 120 fps.
- A 120 Hz display shows one physics step per frame; a 60 Hz display shows two steps per frame.
- The complete engine-plus-layer path stays below 8% of one M-series CPU core at represented 120 Hz.
- Reduce Motion removes autonomous shimmer but preserves voice and pose motion because those carry information.
- Increase Contrast re-solves the same bounded response; it never clips the body to white.
- Harness renders are pinned by seed and exact substep. They never start a live display link.

## Coordinate system and representation

Coordinates are island-local points at 72 pt/in, with origin at the island centre and `+y` upward. The fixed view is 180×34 pt and the raster is always 2×, or 360×68 device pixels.

The body has exactly 97 top/bottom samples: `MercuryMetrics.columns + 1`, with 96 material intervals. No later stage rebuilds another outline.

For material coordinate

$$
 a \in [0,1], \qquad x = (a - \tfrac12)L,
$$

the mean envelope is

$$
 G(a) = 1 - (1-g_{end})(2a-1)^2,
 \qquad g_{end}=0.46.
$$

Its nonzero second derivative prevents a straight flank or stadium capsule from appearing at any amplitude.

## Two-family contact-line model

Each edge is driven by eight complex modes in two families:

- **Varicose modes** $V_m$: local thickness and voice-driven crests.
- **Contact-line modes** $N_m$: independent upper/lower motion—the organic snake component.

Let

$$
 B_m(a)=e^{i m\pi a}.
$$

The log-displacements are

$$
 \theta_T(a)=\sum_{m=1}^{8}\Re\{(V_m+N_m)B_m(a)\},
$$

$$
 \theta_B(a)=\sum_{m=1}^{8}\Re\{(V_m e^{-i m\pi\delta}-N_m)B_m(a)\},
 \qquad \delta=0.11.
$$

The sampled contact lines are

$$
 y_T(a)=H_0G(a)e^{\theta_T(a)},
 \qquad
 y_B(a)=-H_0G(a)e^{\theta_B(a)}.
$$

The exponential has three useful consequences:

1. local thickness stays strictly positive for every finite mode amplitude;
2. detached specks and edge crossings are unrepresentable;
3. multiplicative disturbances read as liquid deformation rather than a waveform added to a capsule.

The lower-edge phase lag prevents both edges from receiving each varicose crest simultaneously. The contact-line family enters the two edges with opposite sign. A capsule scores a Pearson mirror correlation of `+1`; calibration solves the shipped response near zero.

## Capillary–gravity dynamics

Mode $m$ has wavenumber

$$
 k_m=\frac{m\pi}{L}.
$$

The angular frequency uses the finite-depth capillary–gravity dispersion relation

$$
 \omega_m = \tau
 \sqrt{\left(gk_m + \frac{\sigma}{\rho}k_m^3\right)\tanh(k_mH)},
$$

with product tempo $\tau=0.32$. The physical terms are converted to island points and seconds:

- $g=27\,798\ \mathrm{pt/s^2}$;
- $\sigma/\rho=818\,700\ \mathrm{pt^3/s^2}$;
- capillary length $\ell_c=\sqrt{(\sigma/\rho)/g}=5.4262\ \mathrm{pt}$.

The tempo is intentionally not physical. Real mercury waves at this scale are too fast to read as a menu-bar status surface; the dispersion across modes remains physical while one global factor moves the band into a legible range.

Contact-line damping is

$$
 \zeta_m = \frac{\zeta_0}{1+(k_m\ell_c)^2},
 \qquad \zeta_0=0.42.
$$

Long waves therefore settle, while the visible capillary band remains alive. A flat or increasing damping law erased the lobes during prototype sweeps.

### Exact damped-oscillator propagator

Each real component satisfies

$$
 \ddot u + 2\zeta\omega\dot u + \omega^2(u-u_*)=0.
$$

Voiceour never uses Euler integration. For fixed step $h=1/120$, define

$$
 \omega_d=\omega\sqrt{1-\zeta^2},\quad
 d=e^{-\zeta\omega h},\quad
 c=\cos(\omega_d h),\quad
 s=\frac{\sin(\omega_d h)}{\omega_d}.
$$

With offset $q=u-u_*$ and velocity $v$:

$$
 q' = d\left[cq+s(v+\zeta\omega q)\right],
$$

$$
 v' = d\left[cv-s(\omega^2q+\zeta\omega v)\right].
$$

This closed-form 2×2 transition is replayable and batch-independent: advancing 120 single steps produces the same state as one `advance(steps: 120)` call.

### Stationary autonomous motion

Without Reduce Motion, each mode receives a deterministic Gaussian velocity kick keyed by `(session seed, family, substep, mode)`. For

$$
 \ddot u + 2\zeta\omega\dot u + \omega^2u=\xi,
$$

the stationary variance is

$$
 \langle u^2\rangle=\frac{D}{2\zeta\omega^3}.
$$

A substep velocity increment has variance $2Dh$, so the implemented standard deviation is

$$
 \sigma_v=\sqrt{4\zeta\omega^3\,\mathrm{Var}(u)\,h}.
$$

Mode amplitude falls as $m^{-3/2}$. The fundamental RMS is `0.62 pt` at the reference depth. This gives the still-listening body life without letting high modes turn its edge into noise.

Reduce Motion sends every oscillator directly to its current equilibrium and suppresses future stochastic kicks. It does not remove the asymmetric rest draw, voice forcing, pose relaxation, or outcome gesture.

## Voice forcing and traveling crests

The microphone meter supplies 11 samples at 25 Hz, a 440 ms window. For mode $m$, Voiceour computes the half-range complex spectrum

$$
 C_m = \frac1{11}\sum_{j=0}^{10}
 s_j e^{-i m\pi(j+1/2)/11}.
$$

The varicose equilibrium receives $C_m$. The contact-line equilibrium receives its material derivative: multiplication by $i m\pi$. That derivative makes edge motion answer the crest's slope rather than its height.

Between meter updates, the coefficient phase advances by

$$
 \Delta\varphi_m=\frac{m\pi h}{0.44}.
$$

Over one 40 ms meter tick this becomes $m\pi/11$, exactly the phase of shifting the 11-sample buffer by one element. The crest therefore travels continuously right-to-left instead of jumping on every audio callback.

Length and half-height follow pose targets with the exact one-pole transition

$$
 x' = x_* + (x-x_*)e^{-h/\tau_p},
 \qquad \tau_p=0.26\ \mathrm{s}.
$$

Outcome gestures are one-shot velocity impulses: `lurch` kicks the contact-line fundamental; `collapse` kicks the varicose fundamental; `gathered` changes only the pose.

## Exact containment on the drawn envelope

The body must never escape the 180×34 island. A componentwise amplitude clamp was rejected because it protects against a worst-case phase alignment the eight-mode field does not realise and visibly suppresses the liquid.

At each sampled station $j$, the upper edge is

$$
 y_{T,j}=H_0G_j e^{\theta_{T,j}}.
$$

The exact admissible log displacement is

$$
 \theta_{T,j}\le
 \log\frac{H_{max}}{H_0G_j},
$$

and likewise for the lower edge. The containment gauge is the worst normalized violation over both edges and all 97 stations. If the gauge $\gamma>1$, every mode amplitude is retracted by $1/\gamma$. Because $\theta$ is linear in the complex amplitudes, the binding station lands exactly on the envelope.

Outward radial velocity is removed while tangential velocity survives. This is Moreau-style inelastic contact: the state slides along the constraint instead of striking it on every frame. One scalar rescales both mode families, so containment cannot silently turn an independent two-edge body back into a pill.

## One scalar field for pixels and interaction

For a resolved column, let radius and centre be

$$
 r=\frac{y_T-y_B}{2},\qquad c=\frac{y_T+y_B}{2}.
$$

Inside the material span, the signed field is

$$
 \phi(x,y)=r(x)-|y-c(x)|.
$$

Beyond either endpoint it becomes the exact round-cap field

$$
 \phi(x,y)=r-\sqrt{(x-x_c)^2+(y-c)^2}.
$$

Positive values are inside. The same `MercuryField.value` decides:

- pixel coverage;
- panel drag eligibility;
- open-hand cursor routing.

This is a structural safety property, not a visual approximation. Transparent corners of the panel cannot swallow a click.

Coverage is analytic first-order antialiasing:

$$
 \alpha=\operatorname{clamp}
 \left(\frac12+\frac{\phi}{\|\nabla\phi\|p},0,1\right),
$$

where $p$ is one device pixel in island points.

## Half-elliptic crown

A 2D signed field alone produces a flat lozenge. The first prototype added a shoulder to a planar centre; the result had a broad mirror-flat plateau and reflections that stayed mechanically straight while the outline moved.

The shipped surface lifts the complete field into a half ellipse:

$$
 z=\beta\sqrt{2r\tilde\phi-\tilde\phi^2},
 \qquad \beta=0.78.
$$

The field is regularized only for the crown:

$$
 \tilde\phi=\frac{\phi+\sqrt{\phi^2+4\varepsilon^2}}{2},
 \qquad \varepsilon=0.25\ \text{device pixel}.
$$

Coverage still uses the original $\phi$; the regularization merely keeps the elliptic limb's infinite slope finite.

The partial derivatives are

$$
 \frac{\partial z}{\partial\phi}
 =\beta\frac{r-\tilde\phi}{\sqrt{2r\tilde\phi-\tilde\phi^2}}
 \frac{d\tilde\phi}{d\phi},
$$

$$
 \frac{\partial z}{\partial r}
 =\beta\frac{\tilde\phi}{\sqrt{2r\tilde\phi-\tilde\phi^2}}.
$$

The total in-plane gradient is

$$
 \nabla z=
 \frac{\partial z}{\partial\phi}\nabla\phi+
 \frac{\partial z}{\partial r}\nabla r.
$$

The second term is load-bearing. Omitting it lets the outline wiggle while the optical normal ignores changing thickness. The surface normal is

$$
 N=\operatorname{normalize}(-\partial_xz,-\partial_yz,1).
$$

## Finite eye and reflection

The virtual eye sits 1,400 pt above the surface. For pixel $(x,y,z)$, the exact view vector is proportional to

$$
 V=(-x,-y,1400-z).
$$

A distant constant view vector was rejected because highlights then remained pinned while the organism moved. The finite eye makes room bands sweep naturally along changing curvature.

The hot path avoids a square root with a bounded binomial normalization. Define

$$
 x'=\frac{-x}{d},\quad y'=\frac{-y}{d},\quad
 q=x'^2+y'^2,\quad d=1400-z.
$$

Across the complete island $q<0.0044$. Voiceour uses

$$
 (1+q)^{-1/2}\approx
 1-\frac12q+\frac38q^2-\frac5{16}q^3.
$$

Dense tests bound vector error below $10^{-8}$.

With incidence $\mu=N\cdot V$, the mirror direction is

$$
 R=2\mu N-V.
$$

## Why a generated room makes the metal readable

A smooth conductor has no useful colour or structure without something to reflect. Perceptual work by Fleming, Dror, and Adelson shows that natural illumination statistics strongly affect whether an image reads as a material instead of painted shading. Dror, Willsky, and Adelson further measured the heavy-tailed directional structure of real illumination.

Voiceour therefore reflects a generated room rather than painting a highlight. The production room is static for the session. Moving the room was tested and rejected: even slow motion reads as lights rotating around an object instead of a liquid deforming under fixed illumination.

`RecordingOverlayController` draws one fresh random seed for the room and body and latches the persisted `MercuryWorld` when a session begins, so a Settings change applies to the next dictation, never mid-utterance; the harness pins `MercuryMetrics.defaultSeed`. Two worlds share the same prefiltered linear-RGB tables, exact Fresnel, and bounded response path. Room of Ten, below, is the default and the compiled fallback for an unknown persisted value. Spectral Weather, a static lognormal spherical-harmonic room, is a debug comparison selectable only from the `--debug` Settings pane and rendered by the `overlay.island.weather` scene. The room equations and every `make ui-mercury-bench` corpus below use Room of Ten; the octahedral, optical, and response sections apply to both worlds.

### Room of Ten

The retained product name is historical; the final room uses 32 spherical-Gaussian area sources because the 4,096-seed sweep showed that ten left occasional reflection manifolds underlit.

For source axis $a_i$, sharpness $\lambda_i$, intensity $I_i$, and sample direction $d$, the unfiltered lobe is

$$
 L_i(d)=I_i\exp\left[\lambda_i(d\cdot a_i-1)\right].
$$

Source axes use equal-area strata in spherical height and random azimuth. Sharpness is log-uniform on `[20,600]`, corresponding approximately to broad ceiling panels through hard lamps. Intensity is bounded:

$$
 I_i\propto e^{0.55u_i},\qquad u_i\in[-1,1].
$$

Unlike an unbounded lognormal draw, no seed can create an arbitrarily dominant lamp.

Thirty percent of the room is neutral bounce. Source power is normalized so the other 70% is seed-independent. Seven-percent local chroma is built by projecting a random RGB opponent onto the Rec.709 luminance-null plane

$$
 w=(0.2126,0.7152,0.0722),
$$

$$
 c'=c-w\frac{c\cdot w}{w\cdot w}.
$$

The source coefficients are power-centred before tinting. Individual reflections can therefore carry colour while the whole room remains neutral.

### Analytic roughness prefilter

For requested roughness $\alpha$, each spherical Gaussian is widened with

$$
 \lambda' = \frac{\lambda}{1+\lambda\alpha^2}.
$$

Its amplitude is scaled to preserve finite-sphere power. The table footprint roughness `0.019` is added in quadrature to the material level before baking. Production samples the `0.03` level; `0.09` and `0.25` exist for debug and tests.

## Octahedral environment map

The first room table was equirectangular. It needed `acos`, `atan2`, and modulo for every shaded pixel, and its texel solid-angle ratio was about 30.55×. Moving the poles only hid the worst pinwheel.

The shipped 96² chart uses octahedral mapping. For unit direction $v$:

$$
 p=\frac{v}{|v_x|+|v_y|+|v_z|}.
$$

If $p_z<0$, fold the lower hemisphere:

$$
 e_x=(1-|p_y|)\operatorname{sgn}_+(p_x),\qquad
 e_y=(1-|p_x|)\operatorname{sgn}_+(p_y).
$$

Otherwise $e=(p_x,p_y)$. Decoding starts from

$$
 v=(e_x,e_y,1-|e_x|-|e_y|)
$$

and applies the inverse fold before normalization.

A one-texel analytic border is baked outside every square edge. Runtime sampling is therefore one ordinary four-tap bilinear lookup: no trigonometry, face selection, modulo, or seam branch. A dedicated test circles the `-z` identification and rejects a radiance discontinuity.

Octahedral mapping was chosen over a cubemap because it gives one 2D lookup and no six-face branch while retaining similar solid-angle variation. It was chosen over an approximate `atan2/acos` because rebaking the analytic room is more accurate and easier to verify than approximating two transcendental coordinate functions per pixel.

## Exact liquid-mercury Fresnel

The conductor is liquid mercury, with complex index of refraction $\eta(\lambda)=n(\lambda)+ik(\lambda)$ from the optical constants of Inagaki, Arakawa, and Williams. Their data, tabulated in 0.2 eV steps across the visible, is resampled linearly in wavelength onto a 5 nm grid shared with the colorimetric tables: 81 samples from 380 to 780 nm, across which $n$ rises from 0.770 to 2.773 and $k$ from 3.222 to 6.077.

For wavelength $\lambda$ and cosine $\mu$, with $n=n(\lambda)$ and $k=k(\lambda)$, let

$$
 s^2=1-\mu^2,
$$

$$
 t_0=n^2-k^2-s^2,
$$

$$
 a^2+b^2=\sqrt{t_0^2+4n^2k^2},
$$

$$
 a=\sqrt{\frac{a^2+b^2+t_0}{2}}.
$$

Then

$$
 R_s=\frac{(a^2+b^2)+\mu^2-2a\mu}
 {(a^2+b^2)+\mu^2+2a\mu},
$$

$$
 R_p=R_s
 \frac{\mu^2(a^2+b^2)+s^4-2a\mu s^2}
 {\mu^2(a^2+b^2)+s^4+2a\mu s^2},
$$

$$
 F(\lambda,\mu)=\frac{R_s+R_p}{2}.
$$

This is the exact unpolarized smooth-conductor Fresnel used by PBRT and the Lagarde/Born–Wolf derivation, evaluated at every wavelength sample. It gives $F(\lambda,1)=\frac{(n-1)^2+k^2}{(n+1)^2+k^2}$ at normal incidence and $F(\lambda,0)=1$ at grazing. Between them $R_p$ dips through the principal angle, so $F$ is not monotone in $\mu$.

A pixel has to reproduce what an observer integrates, not three point samples of the spectrum. With the CIE 1931 2° colour-matching functions $\bar{\mathbf c}=(\bar x,\bar y,\bar z)^{\mathsf T}$ and $S(\lambda)$ the relative spectral power of CIE illuminant D65, the linear-sRGB reflectance is

$$
 F_{\mathrm{rgb}}(\mu)=W^{-1}M\,
 \frac{\int F(\lambda,\mu)\,S(\lambda)\,\bar{\mathbf c}(\lambda)\,d\lambda}
 {\int S(\lambda)\,\bar y(\lambda)\,d\lambda}.
$$

Both integrals run over 380–780 nm as trapezoid sums of the 81 samples. Numerator and denominator share the weights, so the rule's error cancels exactly for a spectrally flat reflector. $M$ is the IEC 61966-2-1 XYZ-to-linear-sRGB matrix, as published to four decimals:

$$
 M=\begin{pmatrix}
 3.2406 & -1.5372 & -0.4986\\
 -0.9689 & 1.8758 & 0.0415\\
 0.0557 & -0.2040 & 1.0570
 \end{pmatrix}.
$$

$M$ is derived for the four-decimal white chromaticity $(0.3127,0.3290)$ and is itself rounded to four decimals, so it maps the integrated D65 white point $\mathbf X_{\mathrm{D65}}=(0.95041,1,1.08873)$, chromaticity $(0.312725,0.329041)$, to $(0.99987,1.00013,0.99972)$ rather than $(1,1,1)$. The per-channel normalization

$$
 W=\operatorname{diag}(M\mathbf X_{\mathrm{D65}}),\qquad
 \mathbf X_{\mathrm{D65}}=\frac{\int S\,\bar{\mathbf c}\,d\lambda}{\int S\,\bar y\,d\lambda},
$$

maps a perfect reflector, $F\equiv1$, to exactly $(1,1,1)$ instead of tinting it with that residual. Every gain is within $2.8\times10^{-4}$ of 1, so $W$ corrects rounding and cannot hide a wrong matrix. D65 is the sRGB white point, so equal room RGB stands for D65 light; the rasterizer multiplies the room's linear-RGB radiance by $F_{\mathrm{rgb}}(\mu)$ channel by channel.

Sampling $n$ and $k$ only at the dominant wavelengths of the sRGB primaries, 611, 549, and 464 nm rounded to 610, 550, and 460 nm, treats each channel as a delta function. That holds only while $F$ is flat across each colour-matching lobe, and the lobes are roughly 50–100 nm wide at half maximum. At normal incidence mercury is nearly flat: $F(\lambda,1)$ spans 0.772–0.783 across 380–780 nm, and the integral gives $F_{\mathrm{rgb}}(1)=(0.78143,0.77949,0.77844)$, neutral within 0.003, against $(0.78112,0.77940,0.77797)$ from three samples. Toward the principal angle the spectrum fans out, by 0.153 across the visible at $\mu=0.1$. The largest difference is near grazing: at $\mu=0.089$ the integral is 0.0127 lower in red and 0.0090 higher in blue, a slightly bluer limb. The lowest value of any channel is 0.7076, red at $\mu=0.20$; from each channel's minimum, reflectance climbs monotonically to exactly 1 at $\mu=0$. The oracle clamps negative channels at 0, the gamut boundary that $M$'s negative entries let an arbitrary spectrum cross; for mercury the clamp never binds.

Schlick's approximation $F_0+(1-F_0)(1-\mu)^5$, with $F_0=F_{\mathrm{rgb}}(1)$, never falls below $F_0$, so it cannot follow the principal-angle dip. Its maximum absolute error against the spectral reflectance is `0.167` (red, $\mu\approx0.13$), so it was rejected.

Because the spectra and the observer are fixed, $F_{\mathrm{rgb}}$ depends on $\mu$ alone. A 1,024-entry table over $\mu\in[10^{-4},1]$, built once per process from 1,024×81 exact evaluations (about 1.1 ms in a release build), replaces the per-pixel integral with one linear interpolation. The spectral integral remains in source as the oracle. `MercuryPresentationPerformanceTests` sweeps 10,001 cosines and requires maximum error below `1e-4`; the measured maximum is `4.46e-6`.

`MercurySpectralTests` pins the data and the colorimetry:

- the trapezoid integrals of $\bar x$, $\bar y$, and $\bar z$ agree within 0.5% (measured 0.014%), as the CIE's equal-energy normalization requires;
- integrated D65 lands within $10^{-3}$ of the published chromaticity $(0.3127,0.3290)$;
- $M$ alone leaves D65 within $3\times10^{-4}$ of white, and with $W$ a perfect reflector is white to $10^{-12}$;
- the resampled table reproduces the three-wavelength samples: red and green within $10^{-5}$, blue within 0.25%;
- normal-incidence reflectance stays a neutral grey near 0.78, and past the principal angle every channel rises monotonically to 1 at grazing;
- the real-valued algebra matches an independent complex-amplitude evaluation, $r_s=(\mu-w)/(\mu+w)$ and $r_p=(\eta^2\mu-w)/(\eta^2\mu+w)$ with $w=\sqrt{\eta^2-s^2}$, to $6.7\times10^{-16}$;
- `MercuryOptics.exactFresnel` equals this integral, so the table bound above is a bound against the spectrum.

## Bounded display response

Raw room radiance is unbounded and seed-dependent. A plain exposure caused two failures: some seeds crushed the dark bands; others turned sustained speech into a white lozenge.

Voiceour meters scene luminance

$$
 Y=0.2126R+0.7152G+0.0722B
$$

across both listening and speaking bodies for the session's actual room and body seed. It takes scene anchors $s_m=p50$ and $s_h=p98$ and maps them to

$$
 y_m=0.32,\qquad y_h=0.87.
$$

The response is Naka–Rushton:

$$
 y(s)=\frac{c}{1+(h/s)^p},\qquad c=0.94.
$$

For

$$
 q_m=\frac{c}{y_m}-1,\qquad q_h=\frac{c}{y_h}-1,
$$

the two parameters are solved exactly:

$$
 p=\frac{\log(q_m/q_h)}{\log(s_h/s_m)},
$$

$$
 h=s_m q_m^{1/p}.
$$

For every finite positive $s$, $y(s)<c$. The 0.94 ceiling is therefore unreachable analytically, not merely clamped after failure. Increase Contrast solves the same scene anchors to `0.30` and `0.90`, preserving that ceiling.

The mapped luminance rescales the source RGB ratio. If a channel would leave `[0,c]`, the result slides toward neutral along a Rec.709-luminance-null direction. Luminance remains exact while only the impossible chroma is reduced.

### Response and transfer tables

The original scalar map performed two logarithms and one exponential per pixel. The bounded coordinate

$$
 u=\frac{s}{s+h}\in[0,1)
$$

maps the entire finite scene domain to a fixed interval. A 2,048-entry table stores both `y(s)` and gain `y(s)/s`, so the hot path needs one divide and one interpolation.

Linear-to-sRGB uses IEC 61966-2-1:

$$
 E(x)=
 \begin{cases}
 12.92x,&x\le0.0031308,\\
 1.055x^{1/2.4}-0.055,&x>0.0031308.
 \end{cases}
$$

A 4,096-entry interpolation table handles antialiased pixels. A 16,384-entry byte table handles opaque pixels directly. Dense tests require every path to remain within one 8-bit code value of the exact formulas.

## Display-synchronized 120 Hz presentation

The old renderer held each image for 33.3 ms. The physical mode ladder is band-limited well below 15 Hz, so 30 fps did not violate Nyquist; the perceptual defect was zero-order hold of high-contrast specular bands under smooth pursuit. The body looked quantized despite stable physics.

`NSView.displayLink(target:selector:)` is tied to the display containing the view. AppKit stops callbacks while the view is hidden or off-display. Voiceour requests

$$
 f_p=\min(f_{screen,max},120).
$$

The simulation clock never changes. The frame pacer accumulates the display callback interval and consumes

$$
 n=\left\lfloor\frac{r+\Delta t}{1/120}\right\rfloor
$$

fixed substeps, retaining the fractional remainder $r$. A 120 Hz callback consumes one; a 60 Hz callback consumes two; 75 Hz alternates as needed and totals exactly 120 substeps per second.

`CADisplayLink.targetTimestamp - timestamp` outranks the hardware-reported duration because preferred callback rate can differ from panel refresh. Stalls are capped at four substeps and excess elapsed time is discarded: an old body must resume, not fast-forward through unseen motion.

The renderer writes `CGImage` directly to `CALayer.contents` with implicit actions disabled. No frame index, timestamp, or image is published into SwiftUI. `MercuryEngine` returns the same image identity when committed geometry and appearance have not changed, avoiding a layer upload on a zero-step or Reduce Motion callback.

A native probe on the development M4 Pro measured a 120 Hz screen at exactly 121 callbacks over one second: `120.0 Hz`, with both target interval and reported duration at `1/120 s`.

## Calibration instead of magic gains

Three look-defining values are solved against production geometry and optics rather than typed in:

1. Voice drive gain is bisected until median speaking crest prominence is `5.0 pt`.
2. Contact-line gain is bisected until upper/lower mirror correlation is near zero.
3. Every session's display response solves its own p50/p98 room anchors.

Geometry calibration differences a driven run and a zero-drive run from the same seed with Reduce Motion enabled. Because the mode law is linear below containment, static asymmetry and stochastic decoration cancel exactly; the solve measures voice contribution only.

The one-time calibration is warmed in `VoiceourApp.init`. Current gates require launch calibration below 200 ms and first generated room plus first raster below 25 ms.

## Performance investigation and decisions

The accepted material originally rasterized at roughly `1.54 ms` p50. At 120 fps that alone would consume about 18.5% of one core. Time Profiler identified per-pixel transcendental work rather than simulation or `CGImage` upload:

- Naka–Rushton `log/exp` and sRGB `pow` dominated;
- equirectangular `acos/atan2/fmod` became dominant after the first LUT pass;
- exact conductor Fresnel contributed repeated square roots;
- geometry and image creation were already small.

The final optimization stack was deliberately staged so the 30 fps cache remained until the release path passed the 120 Hz gate:

1. process-built exact-source Fresnel LUT;
2. bounded-coordinate response LUT;
3. sRGB interpolation and opaque-byte LUTs;
4. 96² bordered octahedral room map;
5. finite-eye binomial normalization;
6. direct AppKit display link and layer presentation;
7. deletion of the 30 fps hold only after measurement passed.

### Rejected alternatives

| alternative | decision |
| --- | --- |
| Authored rim/highlight/gradient | Rejected. It decouples light from deformation and makes the surface read as illustrated chrome. |
| Moving environment | Rejected. It produces a mechanical rotating-light sweep. |
| Schlick Fresnel | Rejected. It never falls below normal-incidence reflectance, so it misses the principal-angle dip; maximum absolute error is `0.167` against the spectral mercury reflectance. |
| Metal shader | Rejected. The optimized CPU path fits the budget without shader resources, extra packaging, or a second rendering oracle. |
| 1× raster | Rejected. It trades away the accepted limb and text-ground quality instead of fixing the mathematics. |
| Precomputed per-pixel view vectors | Rejected. The table was about 294 KB, larger than M4 Pro L1D, and would evict the room chart to save one normalization. |
| Float-only rewrite | Rejected as a primary lever. Measurement put the gain inside run-to-run noise after the lookup dependencies dominated. Geometry and coverage remain `Double`. |
| Parallel row fill | Rejected. It reduced wall latency but increased process CPU and p99 jitter; the contract is CPU occupancy, not benchmark gaming. |
| Default geometric specular AA | Rejected. Filament-style defaults push roughness past the polished `0.03` level and make mercury look brushed. Crown regularization and baked grid roughness already bound the limb. |
| `TimelineView(.animation)` | Rejected for production cadence. It is system-paced but cannot prove or request the attached screen's exact rate and can starve during window tracking. |
| 30 fps raster hold | Rejected after optimization. It introduced a visible 33.3 ms specular zero-order hold. |

## Measured gates

`make ui-mercury-bench` is permanent and production-backed, and `make check` runs it. The hard-gate column is the contract `MercuryChromeBenchmark` enforces. The result column is the release measurement of 2026-08-29 (`f9ac3ca`) on the development M4 Pro; rerun the target for current values, which it writes to `.build/ui-harness/mercury/benchmark.json`.

| measurement | result | hard gate |
| --- | ---: | ---: |
| generated rooms | 4,096/4,096 pass | zero failures |
| near-white body area | 0.0000 | ≤0.02 |
| reflected-direction coverage | 2.5508 sr | ≥2.0 sr |
| 30 s median luminance drift | 0.7315 stops | ≤1.0 stop |
| launch calibration | 162.4 ms | ≤200 ms |
| cold room + first raster | 9.1 ms | ≤25 ms |
| raster p50 / p99 | 0.5125 / 0.5475 ms | ≤0.55 / 0.70 ms |
| raster CPU at 120 Hz | 0.0621 core | ≤0.066 core |
| engine + layer p50 / p99 | 0.5639 / 0.6978 ms | ≤0.65 / 0.85 ms |
| engine + layer CPU at 120 Hz | 0.0653 core | ≤0.08 core |

A seed fails the 4,096-seed distribution screen when, for either the listening or the speaking reflection manifold, mapped luminance has a median outside `[0.18, 0.55]`, a p95 outside `[0.60, 0.92]`, a p05–p95 span below `0.30`, or less than `1.5` contrast ratio against any of the near-black, mid-grey, and near-white grounds (`0.075`, `0.45`, `0.95`); it also fails when crushed-black area exceeds `0.25`, near-ceiling area `0.02`, p95 local saturation `0.12`, or whole-body colour cast `0.06`. The 64-seed raster corpus additionally fails an Increase Contrast near-white area above `0.02`.

The visual companion is `make ui-mercury`, which writes the contact sheets listed in [ui-harness.md](ui-harness.md#artifacts-and-goldens) under `.build/ui-harness/mercury/`. It is an inspection tool, not a gate.

The relevant automated contracts include:

- `MercurySimulationTests`: exact stepping, containment, asymmetry, voice prominence, Reduce Motion;
- `MercuryCrownTests`: analytic derivatives, full crown, limb regularization;
- `MercuryFieldTests`: connected body and pixel/hit identity;
- `MercuryEnvironmentTests`: positivity, seed replay, power conservation, chroma neutrality, octahedral seam continuity;
- `MercurySpectralTests`: colour-matching and D65 tables against their published integrals and chromaticity, white mapping, sampled-constant provenance, neutral normal incidence, complex-amplitude Fresnel cross-check;
- `MercuryDisplayResponseTests`: anchor solve, monotonicity, unreachable ceiling, Rec.709 gamut handling;
- `MercuryPresentationPerformanceTests`: Fresnel/OETF/response oracle error, view approximation, octahedral round trip, 60/75/120/144 Hz pacing;
- `MercuryEngineTests`: reseeding, duplicate image identity, appearance reraster;
- `MercuryCalibrationTests`: crest-prominence target, independent voice-driven edges, per-room response median for every `MercuryWorld`;
- `make ui-snap`: island and recording-panel scene rasters and accessibility dumps (`make ui-list` is the inventory);
- `make ui-flow`: overlay journeys among the semantic flows (`make ui-flow-list` is the inventory).

## Privacy and accessibility boundaries

The room is generated from a seed. It does not read wallpaper, windows, desktop pixels, camera data, or any network resource. No additional permission follows from the material.

`MercurySurfaceView` is hidden from accessibility and hit-testing. The stable 180×34 `Dictation status` element remains in SwiftUI and carries the human-readable value plus named Finish/Cancel actions. `MercuryHitRegion` remains AppKit's single click/cursor oracle.

## Source map

| concern | source |
| --- | --- |
| physical constants and measured targets | `Sources/Voiceour/MercuryMetrics.swift` |
| world selection and persisted fallback | `Sources/VoiceCore/MercuryWorld.swift` |
| deterministic random streams | `Sources/Voiceour/MercuryNoise.swift` |
| pose ladder and targets | `Sources/Voiceour/MercuryPose.swift` |
| two-family exact mode solver | `Sources/Voiceour/MercurySimulation.swift` |
| calibrated gains and room metering | `Sources/Voiceour/MercuryCalibration.swift` |
| signed silhouette | `Sources/Voiceour/MercuryField.swift` |
| crown and total derivative | `Sources/Voiceour/MercuryCrown.swift` |
| static generated rooms and octahedral chart | `Sources/Voiceour/MercuryEnvironment.swift` |
| spectral conductor reflectance (CIE 1931 observer, D65, liquid-mercury n and k) | `Sources/Voiceour/MercurySpectral.swift` |
| exact-source optical LUTs | `Sources/Voiceour/MercuryOptics.swift` |
| bounded Naka–Rushton display response | `Sources/Voiceour/MercuryDisplayResponse.swift` |
| production CPU shading | `Sources/Voiceour/MercuryRasterizer.swift` |
| fixed-step engine, image cache, and hit region | `Sources/Voiceour/MercuryRibbon.swift` |
| frame pacer, display link, and layer presentation | `Sources/Voiceour/MercuryDisplayLink.swift` |
| material/performance corpus | `Sources/Voiceour/UIHarness/MercuryChromeBenchmark.swift` |
| contact sheets | `Sources/Voiceour/UIHarness/MercurySheet.swift` |

## References

- Fleming, Dror, and Adelson, [“Real-world illumination and the perception of surface reflectance properties”](https://doi.org/10.1167/3.5.3), *Journal of Vision* 3(5), 2003.
- Dror, Willsky, and Adelson, [“Statistical characterization of real-world illumination”](https://doi.org/10.1167/4.9.11), *Journal of Vision* 4(9), 2004.
- Inagaki, Arakawa, and Williams, [“Optical properties of liquid mercury”](https://doi.org/10.1103/PhysRevB.23.5246), *Physical Review B* 23, 1981, for mercury's $n(\lambda)$ and $k(\lambda)$. Voiceour resamples the CC0 tabulation at [refractiveindex.info](https://refractiveindex.info/?shelf=main&book=Hg&page=Inagaki) (`database/data/main/Hg/nk/Inagaki.yml`) linearly in wavelength onto the 5 nm grid.
- Pharr, Jakob, and Humphreys, [PBRT v4: Conductor BRDF](https://www.pbr-book.org/4ed/Reflection_Models/Conductor_BRDF), for smooth-conductor complex Fresnel and reflection conventions.
- Lagarde, [“Memo on Fresnel equations”](https://seblagarde.wordpress.com/2013/04/29/memo-on-fresnel-equations/), 2013, for the real-valued air–conductor form used as the table oracle.
- CIE, [“Colour-matching functions of CIE 1931 standard colorimetric observer”](https://doi.org/10.25039/CIE.DS.xvudnb9b), dataset, 2019, from CIE 018:2019 Table 6, for $\bar x$, $\bar y$, and $\bar z$. Voiceour embeds every fifth 1 nm row from 380 to 780 nm, identical to CVRL's 5 nm `ciexyz31` table.
- CIE, [“CIE standard illuminant D65”](https://doi.org/10.25039/CIE.DS.hjfjmt59), dataset, 2019, from ISO/CIE 11664-2:2022 Table B.1, for the daylight spectrum $S$. Voiceour embeds every fifth 1 nm row from 380 to 780 nm.
- Cigolle et al., [“Survey of Efficient Representations for Independent Unit Vectors”](https://jcgt.org/published/0003/02/01/), *JCGT* 3(2), 2014, for octahedral unit-vector mapping.
- Naka and Rushton, [“S-potentials from colour units in the retina of fish”](https://doi.org/10.1113/jphysiol.1966.sp008001), *Journal of Physiology* 185(3), 1966, for the bounded response family.
- Apple, [`NSView.displayLink(target:selector:)`](https://developer.apple.com/documentation/appkit/nsview/displaylink(target:selector:)), for view-bound, hidden-aware display synchronization on macOS 14+.
- Glocker and Pfeiffer, [“Rigid-Body Dynamics with Friction and Impact”](https://doi.org/10.1137/S0036144599360110), *SIAM Review* 43(1), 2001, for the nonsmooth-contact context behind the Moreau-style envelope retraction.

## Maintenance rule

This document describes the shipping renderer, not a menu of optional effects. A future change to the field, mode law, crown, room distribution, optics, response, cadence, or hard benchmark must update this document in the same commit. Raw brainstorm artifacts are disposable. Production code, tests, and the benchmark gates are the enforced contract; this file is their derivation and rationale, and README.md and AGENTS.md remain the authority for what the island must do.
