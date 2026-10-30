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
- The body is a viscoelastic gel: struck, it rings; held, it creeps; squash and stretch trade length for thickness at constant volume.
- The visible material is polished liquid mercury: structured dark and bright bands, subtle room colour, and grazing reflectance—not a white pill.
- Physics advances in exact `1/120 s` steps. Presentation follows the display containing the panel, capped at 120 fps.
- A 120 Hz display shows one physics step per frame; a 60 Hz display shows two steps per frame.
- The complete engine-plus-layer path stays below 8% of one M-series CPU core at represented 120 Hz.
- Reduce Motion removes autonomous shimmer, emergence, squash-and-stretch overshoot, and the body shape's gesture and arrival kicks, but preserves voice and pose motion because those carry information.
- Increase Contrast re-solves the same bounded response; it never clips the body to white.
- Harness renders are pinned by seed and exact substep. They never start a live display link.

## Coordinate system and representation

Coordinates are canvas-local points at 72 pt/in, with origin at the canvas centre and `+y` upward. `RecordingOverlayLayout` supplies the canvas, and the raster always covers it at 2×. The island's canvas is 196×34 pt, inset 32 pt from the left and 16 pt from the top of its 260×80 pt panel: 392×68 device pixels. It runs 8 pt past each end of the 180×34 pt envelope that placement and the `Dictation status` element measure, so the panel and the status frame stay where they are while a round end swayed to the end of its track is never cut ([Exact containment](#exact-containment-on-the-drawn-envelope)). The collar's canvas is the whole panel, hung flush from the screen's top edge and centred on the camera housing. Around a $w_h\times h_h$ housing it measures

$$
 \bigl(w_h+2(\rho_e+E)+8\bigr)\times\bigl(h_h+H_{max}+3\bigr),
$$

with fillet radius $\rho_e=4.5$ pt, ear length $E=56$ pt, and $H_{max}=17$ pt: 314×52 pt around the 185×32 pt housing and 349×58 pt around the 220×38 pt one. The width reaches each fillet and ear plus 4 pt for a round end; the height holds the deepest chin plus a 3 pt margin for its bleed.

`RecordingOverlayLayout.forDisplay(_:)` lays the collar only around a constructible notch: a camera housing on a display outside any mirror set, deeper than $\rho_e+6$ pt and wider than its two corners. Every other display gets the island. `RecordingOverlayController` does not select the collar, so the panel presents the island on every display.

### Spine and chart

The body's material coordinate lies along a `MercurySpine`: arc length $s\in[0,S]$, unit tangent $\mathbf T$, unit normal $\mathbf N$, and signed curvature $\kappa$, with $d\mathbf T/ds=-\kappa\mathbf N$ and $d\mathbf N/ds=\kappa\mathbf T$. A point's chart $(s,n)$ is the arc length of its nearest spine point and its signed offset along $\mathbf N$.

- **Island**: one straight 196 pt run, so $s=x+98$, $n=y$, and $\mathbf N=+\hat y$.
- **Collar**: the housing's own outline as a G³ curve of nine primitives: an ear along the screen's top edge, a concave fillet, a wall, a convex corner, the bottom run, then the same four mirrored. Each bend keeps the footprint of a circular arc, radius $\rho_e$ for a fillet and $\rho$ for a corner, but eases its curvature in and out ([Eased bends](#eased-bends)): $\kappa$ runs from 0 to a plateau of $1/R_p$ across a corner and $-1/R_p$ across a fillet, and is 0 on the straight runs. The layout sets $\rho=\operatorname{clamp}(0.44\,h_h,6,16)$ pt, and `MercurySpine` limits it to $\min(h_h-\rho_e,\,w_h/2)$ so no run is negative. $\mathbf N$ is the right-hand normal of the left-to-right traversal and points out of the housing everywhere: down along the ears and the bottom, outward on the walls.

`chart(at:)` finds the exact nearest spine point. Each primitive owns a normal domain: a slab for a straight run, and for a bend the quadrant between its two end normals, which meet at its circle's centre. The curve is G³ and the ears continue straight past their ends, so the nearest point always lies in the domain of the primitive that owns it. At most two primitives ever compete, an ear against the wall or corner beside it, and the right half folds onto the left. Inside a bend, the plateau's own end normals meet at the plateau's centre and split the quadrant: between them the foot is radial and the chart is closed-form, as it is on the straight runs; beyond either lies that ramp's region, where Newton's method finds the foot ([Eased bends](#eased-bends)). The chart returns $s$, $n$, $\mathbf T$, $\mathbf N$, the metric

$$
 J=1+\kappa n,\qquad \nabla s=\frac{\mathbf T}{J},\qquad \nabla n=\mathbf N,
$$

whether the primitive is a horizontal run (the island, the bottom, an ear), where $s$ depends on $x$ alone, and the point's distance outside the housing's rim. The chart is nil strictly inside the housing, including its rounded corners and its continuation into the bezel, and above the screen's top edge.

The housing keeps its circular corners: the hardware alone decides where the chart is nil. A corner's eased spine is squarer than the housing's circle and stands outside its rim by up to $g=0.04873\,\rho$ at the corner's middle, `MercurySpine.rimGap`, so a corner's chart reaches offsets down to $n=-g$, into the sliver between the two. Everywhere else the collar's inner half, $n<0$, lies under the housing or above the screen, where nothing is drawn or hit. The body's inner half covers the sliver, so the visible body begins exactly at the hardware's edge: the notch's rim is the liquid's contact line, the way a drop meets a wall it wets, and no rim is drawn. `Chart.rimDistance` is the distance outside that edge. On the walls and the bottom it equals $n$; on a corner it is the distance outside the housing's circular corner; it is infinite exactly where the chart does not border the housing, on the ears and the fillets. Coverage reads it, so exclusion and the rim's antialiasing both follow the circular hardware outline rather than the spine.

### Eased bends

A circular arc's curvature jumps from $\pm1/r$ to 0 where it meets a straight run. The metric $J$ jumps with it, and so does the field's gradient wherever the body's edges slope along the spine, because the rate along the body divides by $J$ ([One scalar field](#one-scalar-field-for-pixels-and-interaction)). On a mirror that kink draws a seam down the reflection. Every bend, convex corner and concave fillet alike, therefore turns through a ramp–plateau curvature profile. With $u$ the arc length into a bend of length $S$ and $q=0.15$,

$$
 |\kappa(u)|=\kappa_p\times
 \begin{cases}
 \sin^2\dfrac{\pi u}{2qS}, & u\le qS,\\[4pt]
 1, & qS\le u\le(1-q)S,\\[4pt]
 \sin^2\dfrac{\pi(S-u)}{2qS}, & u\ge(1-q)S.
 \end{cases}
$$

Curvature rises from 0 over the first ramp, holds on the plateau, and falls back to 0 over the last ramp. A $\sin^2$ ramp is flat at both of its ends, so curvature and its slope are both continuous, against the straight runs and at each hand-over to the plateau: the curve is G³. Over a ramp, with $\tau=u/qS$, the tangent turns through

$$
 \theta(\tau)=\theta_q\left(\tau-\frac{\sin\pi\tau}{\pi}\right),
 \qquad
 \theta_q=\frac{\pi q}{4(1-q)}=7.94^\circ,
$$

and the plateau, an exact circular arc of radius $R_p=1/\kappa_p$, turns the rest of the quarter turn, from $7.94^\circ$ to $82.06^\circ$.

Each bend keeps its circle's footprint: it runs its radius $r$, $\rho$ or $\rho_e$, across and $r$ down, so it begins and ends at the circle's tangent points, and the walls, ears, and bottom run keep their lengths. That fixes

$$
 S=1.62051\,r,\qquad \kappa_p\,r=1.14038,\qquad R_p=0.87690\,r,
$$

against a circle's $S=\tfrac\pi2r=1.57080\,r$. The plateau is centred $0.12150\,r$ from the circle's centre along each axis, toward the bend's corner, and the bend is squarer than the circle by $0.04873\,r$ at its middle: 0.686 pt at the 185×32 pt housing's $\rho=14.08$ pt, 0.780 pt at $\rho=16$ pt, and 0.219 pt on a fillet. The longer bends lengthen the collar's corner and fillet regions, and with them every collar length the [pose ladder](#pose-ladder) measures along the spine.

A ramp's points have no closed form. `MercurySpine` integrates one ramp once, by eight-point Gauss–Legendre on each of 256 intervals, and interpolates between the 257 nodes by cubic Hermite on their exact tangents, to $3\times10^{-12}$ pt on the largest corner, $\rho=16$ pt. Every ramp of every bend is that one curve reflected and scaled, and its turn and curvature stay closed-form.

On a ramp the chart's foot solves the tangent-orthogonality condition

$$
 f(\tau)=\bigl(\mathbf p-\mathbf C(\tau)\bigr)\cdot\mathbf T(\tau)=0,
 \qquad
 \frac{df}{du}=-(1+\kappa n),
$$

so each Newton step is $f/(1+\kappa n)$. Newton starts from the true foot, tabulated on a 41×17 grid over the ramp's region, built once at first use by continuation from the straight run's end normal and read bilinearly; every ramp is the same curve at another scale, so one grid serves them all. It stops at the first step under $10^{-10}$ pt, which the tests require within four steps; measured on their dense grids, a corner's foot takes at most three (mean 2.94) and a fillet's at most four (mean 2.77). Should four not converge, or a step reach past the ramp's centre of curvature, a safeguarded Newton–bisection on $[0,1]$ finishes the solve. It is always bracketed: $f(0)$ is the point's distance along the straight run past its end, never negative, and $f(1)$ is the point's side of the plateau's end normal, negative on the ramp's own side. A point in a fillet's deepest core, behind the plateau's centre, lies beyond both end normals, where $f$ is no longer monotone; it takes the nearer of the two ramps' feet, which matches a brute-force search over the whole fillet square.

The eased bends remove the seam. Over 24 speaking bodies on the two fixture housings, the largest jump of the encoded reflection across each join, in 8-bit codes, joins named in traversal order:

| join | circular arcs, 185×32 pt | circular arcs, 220×38 pt | eased bends |
| --- | ---: | ---: | ---: |
| corner → bottom | 10.22 | 9.50 | ≤0.0002 |
| bottom → corner | 8.59 | 5.80 | ≤0.0002 |
| ear → fillet | 4.50 | 4.39 | ≤0.0002 |
| fillet → wall | 2.39 | 2.00 | ≤0.0002 |

Across the same joins the field's gradient jumps by at most $8\times10^{-9}$, where circular arcs made it jump by $2\times10^{-3}$ to $4\times10^{-2}$.

### Taper

The taper $\Lambda(s)\in(0,1]$, `taper(at:)`, is the fraction of $H_{max}$ a station at $s$ may draw. It is 1 along the whole island and along the collar's bottom run, the chin under the notch. It is $\Lambda_{film}=3.5/17$, a 3.5 pt film, on the walls, fillets, and ears, which lie in the menu-bar band. Across each convex corner it is a smoothstep in the corner's tangent angle $\psi$, measured up from the bottom:

$$
 \Lambda=1-(1-\Lambda_{film})\,u^2(3-2u),
 \qquad u=\operatorname{clamp}\left(\frac{\psi-30^\circ}{40^\circ},0,1\right).
$$

Through the lowest 30° the corner is still the chin's shoulder and keeps full thickness, so the chin stays one round piece; by 70° it is the foot of the wall, in the band, and already film. Both ends lie on the corner's plateau, which turns at the constant rate $1/R_p$, so $\psi$ runs linearly with arc length across the whole blend, 40° of plateau: 8.6 pt at $\rho=14.08$ pt and 9.8 pt at $\rho=16$ pt. The smoothstep is flat at both ends, so $\Lambda$ is C¹ and the edge has no kink. `taperSlope(at:)` is the analytic $\Lambda'(s)$: on each corner, the smoothstep's derivative in angle divided by $R_p$ and signed by the traversal; zero everywhere else. So `taperBounds(from:to:)`, the taper's least and greatest values and its steepest slope over a range of arc length, is exact as well, and the field bounds each piece of the body by it without sampling the taper. Beside the notch, nothing thicker than the film rises above the corner centres.

The film must stay thinner than the fillet's plateau. A concave arc's offsets converge on its centre and collapse at $n=R_p$, where $J$ vanishes and every point of the plateau is equally near. `MercurySpine.init(collar:)` requires the band film to stay under $0.87690\,\rho_e$: the 3.5 pt film under the 4.5 pt fillet's 3.946 pt plateau keeps $J\ge1-3.5/3.946\approx0.113$ and a unique nearest point. The fillet's ramps curve less than its plateau, so $J$ is larger there.

### Stations and mean envelope

The body has exactly 97 top/bottom samples: `MercuryMetrics.columns + 1`, with 96 material intervals. No later stage rebuilds another outline. Both edges are normal offsets from the spine; on the collar the top edge is the outer, visible edge and the bottom edge lies under the housing.

The span of length $L$ is centred on $\bar s=S/2+\delta$: the middle of the spine, displaced by the body's sway $\delta$ ([Global body shape](#global-body-shape)). For material coordinate

$$
 a \in [0,1], \qquad s = \bar s + (a - \tfrac12)L,
$$

the mean envelope is

$$
 G(a) = 1 - (1-g_{end})(2a-1)^2,
 \qquad g_{end}=0.46.
$$

Its nonzero second derivative prevents a straight flank or stadium capsule from appearing at any amplitude.

The [body shape](#global-body-shape)'s two modulators reshape it:

$$
 G_s(a)=G(a)\,\bigl[1+\mathrm{skew}\,(2a-1)\bigr]\Bigl[1-\mathrm{neck}\,e^{-((a-1/2)/w)^2}\Bigr],
 \qquad w=0.11.
$$

The skew's ramp is odd about the middle and $G$ is even, so it moves area from one end to the other and keeps the total: skew 0.4 sets the two ends' thickness 70/30, and the range $[-0.6,0.6]$ stops at 80/20. The neck's Gaussian waist is a fifth of the body wide at half depth, about 18 of the 97 stations: wide enough that the field draws a smooth thread rather than a kink, narrow enough that both halves keep their full thickness. Its range $[0,0.85]$ leaves the waist at least 15% of its thickness, so the deepest pinch reads as two drips joined by a thread and never as two bodies.

The shaped envelope is drawn at the body shape's own half-height, $H_0=H$. Unshaped, $G$ peaks at exactly 1 at the centre; a skew lifts the thick end above it, by at most 13% at the widest skew, so $\max_a G_s(a)\le1.133$. The [containment gauge](#exact-containment-on-the-drawn-envelope) scales crests back but cannot move a mean envelope that already stands at the ceiling, so the body shape holds $H$ under a height wall one crest headroom below $H_{max}$:

$$
 H\le H_w=H_{max}\,e^{-0.25}=13.24\ \text{pt}.
$$

The headroom, 0.25 in the gauge's units of $\ln\bigl(H_{max}/(H_0G_s)\bigr)$, is containment budget the body's own depth never spends. The widest skew spends $\ln1.133=0.125$ of it, half, so every station keeps a budget of at least 0.125 for its crests. A body held only to $H_{max}$ itself would meet the ceiling: the speaking body gathering into processing overshoots its aspect into its wall, and at $H_{max}$ the budget at its centre would reach zero and the gauge would erase every mode for a substep. No pose is clamped at rest: the deepest, processing, is 12.5 pt, and the ladder's one skewed pose, the 11 pt lurch, peaks at 1.07.

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
 y_T(a)=H_0G_s(a)e^{\theta_T(a)},
 \qquad
 y_B(a)=-H_0G_s(a)e^{\theta_B(a)}.
$$

The exponential has three useful consequences:

1. local thickness stays strictly positive for every finite mode amplitude;
2. detached specks and edge crossings are unrepresentable;
3. multiplicative disturbances read as liquid deformation rather than a waveform added to a capsule.

The lower-edge phase lag prevents both edges from receiving each varicose crest simultaneously. The contact-line family enters the two edges with opposite sign. A capsule scores a Pearson mirror correlation of `+1`; calibration solves the shipped response near zero.

## Gel dynamics

Every real component of every mode is a standard linear solid, the Zener model of a gel: a rubbery network of stiffness $\Omega_\infty^2$ in parallel with a Maxwell arm, a spring $\Omega_1^2$ in series with a dashpot of relaxation time $\tau$. Per unit modal mass, with offset $q=u-u_*$ from the equilibrium $u_*$, velocity $v$, and the arm's stress $\sigma$ in acceleration units,

$$
 \dot q=v,\qquad
 \dot v=-\Omega_\infty^2q-b\,v-\sigma,\qquad
 \dot\sigma=\Omega_1^2v-\frac{\sigma}{\tau}.
$$

A capillary–gravity oscillator alone rings at one frequency and forgets how it was deformed; the arm is the one internal variable a gel adds. Driven at angular frequency $\omega$, it contributes the complex stiffness

$$
 \Omega_1^2\frac{i\omega\tau}{1+i\omega\tau}
 =\Omega_1^2\frac{\omega^2\tau^2}{1+\omega^2\tau^2}
 +i\,\Omega_1^2\frac{\omega\tau}{1+\omega^2\tau^2}.
$$

- **Jelly.** The storage part runs from 0 at $\omega\tau\ll1$ to $\Omega_1^2$ at $\omega\tau\gg1$, so the total stiffness rises from the rubbery $\Omega_\infty^2$ to the glassy $\Omega_g^2=\Omega_\infty^2+\Omega_1^2$. Motion too fast for the dashpot meets both springs while the arm's loss falls as $1/(\omega\tau)$: a struck mode wobbles near $\Omega_g$.
- **Gum.** The loss part peaks at $\omega\tau=1$. A deformation held for $\tau$ or longer drains its stress through the dashpot, and on release the mode creeps home on the rubbery spring instead of springing back on the glassy one. The material remembers how long it was held.

The island's speaking fundamental, $k=\pi/160$ pt⁻¹ on the 9.5 pt body, has $\Omega_g=13.17$ rad/s, so $\Omega_g\tau\approx4$. Struck, it changes sign six times before its swing falls below 5% of the peak. Grabbed to a unit offset, which loads the arm at once, and held still, it swings 0.537 past equilibrium on release after a 0.05 s hold and 0.151 after a 2 s hold.

### Dispersion

Mode $m$ has wavenumber

$$
 k_m=\frac{m\pi}{L}
$$

on a pool $H_0$ deep, with $L$ floored at 1 pt and $H_0$ at 0.25 pt. Its gel is

$$
 \Omega_\infty^2=\mathrm{tempo}^2\left(gk_m+\frac{\gamma}{\rho}k_m^3\right)\tanh(k_mH_0)+(c_\infty k_m)^2,
 \qquad
 \Omega_1^2=(c_1k_m)^2,
$$

$$
 b=2\zeta_0\Omega_g+2\nu k_m^2,
 \qquad
 \tau=0.30\ \mathrm{s}.
$$

The first term is the finite-depth capillary–gravity dispersion of a mercury pool, with the physical terms converted to island points and seconds:

- $g=27\,798\ \mathrm{pt/s^2}$;
- surface tension over density $\gamma/\rho=818\,700\ \mathrm{pt^3/s^2}$;
- product tempo $0.32$.

The tempo is intentionally not physical. Real mercury waves at this scale are too fast to read as a menu-bar status surface; the dispersion across modes remains physical while one global factor moves the band into a legible range. The gel adds stiffness and memory to the liquid and never removes it.

A shear wave of speed $c$ on a gel has modal stiffness $(ck)^2$. The rubbery network's $c_\infty=505$ pt/s and the arm's $c_1=410$ pt/s are tuned at the body's tempo, not measured. Their glassy speed $\sqrt{c_\infty^2+c_1^2}\approx650$ pt/s puts mode $m$ of the 160 pt speaking body at $\Omega_g\approx13m$ rad/s, above the $m\pi/0.44\approx7.1m$ rad/s at which the voice advects its crests. The voice therefore drives every crest below its glassy resonance: quasi-static and springy, never a ring the voice did not ask for.

Loss outside the arm has two parts. $\zeta_0=0.10$ is a damping ratio against the glassy frequency, small because the arm already supplies the frequency-selective loss. $\nu=200$ pt²/s is an effective viscosity at the body's tempo, and $2\nu k^2$ is the $k^2$ law of viscous wave damping: short modes die while long ones ring. Every term is positive for $k>0$ and $H_0>0$, so every mode is strictly dissipative.

### Exact propagator

Across one step $h=1/120$ s in which the equilibrium does not move, the state $x=(q,v,\sigma)^{\mathsf T}$ advances exactly as $x'=\Phi x$, with

$$
 \Phi=e^{Ah},
 \qquad
 A=\begin{pmatrix}
 0 & 1 & 0\\
 -\Omega_\infty^2 & -b & -1\\
 0 & \Omega_1^2 & -1/\tau
 \end{pmatrix}.
$$

Voiceour never uses Euler integration. $\Phi$ is not an integrator: it has no order, no stability limit, and no step-size dependence beyond rounding. One $\Phi$ per mode serves both families and both real components, and it is rebuilt only when $(L,H_0)$ changes, so a held pose, a pinned frame, and calibration build it once.

$\Phi$ is computed by scaling and squaring with the diagonal [6/6] Padé approximant (Higham, 2005):

$$
 e^X\approx\bigl[r_6\bigl(2^{-s}X\bigr)\bigr]^{2^s},
 \qquad
 r_6(X)=p(-X)^{-1}p(X),
 \qquad
 p(X)=\sum_{j=0}^{6}\frac{(12-j)!\,6!}{12!\,j!\,(6-j)!}X^j.
$$

$s=\max\bigl(0,\lceil\log_2(2\lVert X\rVert_1)\rceil\bigr)$, read exactly off the binary exponent, brings the scaled argument inside $\theta_6\approx0.54$, where the approximant's backward error is below the unit roundoff; LU with partial pivoting solves the denominator. The one preprocessing step balances the generator before $X=\tilde Ah$ is formed:

$$
 \tilde A=DAD^{-1},
 \qquad
 D=\operatorname{diag}(2^e,1,2^{-e}),
 \qquad
 2^e\le\Omega_g<2^{e+1},
$$

with $D=I$ below 1 rad/s, and $\Phi=D^{-1}e^{\tilde Ah}D$. A power-of-two similarity is exact in floating point and brings every entry to the order of $\Omega_g$, so the norm that chooses $s$ measures the dynamics rather than the units. Across the modal range, $k$ from $\pi/400$ to $8\pi/20$ pt⁻¹ at depths 0.25–17 pt, the stiffest mode unbalanced needs 14 squarings and is good to $2\times10^{-12}$ of $\lVert\Phi\rVert$; balanced, it needs 5, and every mode is within $5\times10^{-15}$ of a 50-digit reference.

The transition is exact, so it is replayable and batch-independent: advancing 120 single substeps produces the same state as one `advance(steps: 120)` call, and one 100-substep propagator applied six times agrees with 600 single substeps to $10^{-12}$.

Between steps the equilibrium may move, and how it moves decides the stress. Both cases are exact for a piecewise-constant equilibrium:

- **A force** $f$ acts on the mass. It shifts the rubbery equilibrium by $f/\Omega_\infty^2$ and leaves $\sigma$ untouched: the arm only ever feels the motion the force produces. The voice and a moving panel are forces.
- **A new reference configuration** moves the point both springs are referenced to. A pose step $\Delta$ shifts $q$ by $-\Delta$ and $\sigma$ by $-\Omega_1^2\Delta$, because the arm's spring stretches at once and its dashpot cannot. The step meets the glassy stiffness first, and then the arm relaxes.

### Stationary autonomous motion

Without Reduce Motion, each mode takes a deterministic Gaussian velocity kick every substep, keyed by `(session seed, family, substep, mode)`:

$$
 x\leftarrow\Phi x+\sigma_w\,e\,w,
 \qquad
 e=(0,1,0)^{\mathsf T},
 \qquad
 w\sim\mathcal N(0,1),
$$

independently for each real component. The kick lands once per substep, so the exact statistic of the process the simulation runs is the stationary covariance of this discrete recursion; the continuous-time variance is only its $h\to0$ limit. For a unit kick that covariance solves the discrete Lyapunov equation

$$
 P=\Phi P\Phi^{\mathsf T}+ee^{\mathsf T},
$$

uniquely, because every mode is strictly dissipative. Voiceour solves its 9×9 Kronecker form

$$
 \bigl(I-\tilde\Phi\otimes\tilde\Phi\bigr)\operatorname{vec}\tilde P=\operatorname{vec}\bigl(ee^{\mathsf T}\bigr),
 \qquad
 \tilde\Phi=D\Phi D^{-1},
$$

by Gaussian elimination with partial pivoting in the balanced coordinates, where every entry of $\tilde\Phi$ is of order one. $De=e$, so the kick is unchanged there, and $P=D^{-1}\tilde PD^{-1}$ is exact. The residual is at most $3.5\times10^{-16}\lVert P\rVert$, and the solve agrees to $10^{-10}$ with the impulse-response sum $\sum_n\Phi^nee^{\mathsf T}\Phi^{n\mathsf T}$, which shares none of its algebra. The kick scale is then

$$
 \sigma_w=\sqrt{\frac{\mathrm{Var}_{target}}{P_{00}}},
 \qquad
 \mathrm{Var}_{target}=\left(\frac{0.62\ \mathrm{pt}}{H_0}\,m^{-3/2}\right)^2.
$$

$\mathrm{Var}_{target}$ is in the log-displacement units of $\theta$, so each mode component shimmers by $0.62\,m^{-3/2}$ pt of edge displacement at the body's centre, however stiff, damped, or creeping the gel makes the mode. The $m^{-3/2}$ fall gives the still-listening body life without letting high modes turn its edge into noise. Kick scales are built only when kicks are due at the current extent, so Reduce Motion never pays for the solve.

Reduce Motion sends every mode directly to its current equilibrium, with no velocity or stress, and suppresses future stochastic kicks. It does not remove the asymmetric rest draw, voice forcing, pose motion, or an outcome gesture's mode impulse.

## Voice forcing and traveling crests

The microphone meter supplies 11 samples at 25 Hz, a 440 ms window. For mode $m$, Voiceour computes the half-range complex spectrum

$$
 C_m = \frac1{11}\sum_{j=0}^{10}
 s_j e^{-i m\pi(j+1/2)/11}.
$$

The varicose equilibrium receives $C_m$. The contact-line equilibrium receives its material derivative: multiplication by $i m\pi$. That derivative makes edge motion answer the crest's slope rather than its height. Each equilibrium is the seed's rest draw plus this voice term, scaled by its calibrated gain and the pose's drive scale, and it acts on the mode as a [force](#exact-propagator): moving it never touches the arm's stress.

Between meter updates, the coefficient phase advances by

$$
 \Delta\varphi_m=\frac{m\pi h}{0.44}.
$$

Over one 40 ms meter tick this becomes $m\pi/11$, exactly the phase of shifting the 11-sample buffer by one element. The crest therefore travels continuously right-to-left instead of jumping on every audio callback.

## Global body shape

`MercuryBodyShape` carries the body the modes ride on: how much mercury there is, how it is proportioned, where it sits on its spine, and the two envelope modulators gestures are made of. Every coordinate advances by an exact propagator one substep at a time, so a body that took $N$ substeps is the same body however they were batched.

The extent is parameterized by volume and log-aspect,

$$
 V=LH,\qquad \alpha=\ln\frac{L}{H},
 \qquad\text{so}\qquad
 L=\sqrt{Ve^{\alpha}},\qquad H=\sqrt{Ve^{-\alpha}},
$$

and $LH=V$ by construction. $V$ is in pt², proportional to the area the body draws, and $H$ is the mean envelope's value at the body's centre before a neck pinches it. Squash and stretch, the jelly's signature, is motion in $\alpha$ alone: it moves area between length and thickness without creating or destroying any. Incompressibility is a choice of coordinates, not a constraint an integrator could drift from.

**Volume** is mass flowing through the notch, not a shape. It is critically damped at $\omega_V=10$ rad/s, the fastest second-order response that cannot overshoot from rest; an overshoot would be mercury leaving the housing and flowing back. The exact one-substep transition of $\ddot x+2\omega\dot x+\omega^2x=0$ is

$$
 x'=e^{-\omega h}\bigl[(1+\omega h)\,x+h\,\dot x\bigr],
 \qquad
 \dot x'=e^{-\omega h}\bigl[-\omega^2h\,x+(1-\omega h)\,\dot x\bigr],
$$

and its response to a moving target is the positive kernel $\omega^2te^{-\omega t}$, so from rest it never leaves the range of the targets it is given. A first-order law would start the flow with a jump in rate; this one starts it from zero, so the body emerges instead of appearing. 90% of a step takes 0.39 s.

**Aspect** is a [Zener gel](#gel-dynamics) with $\Omega_\infty=13.8$ and $\Omega_1=8.8$ rad/s ($\Omega_g=16.4$), loss ratio 0.14 against $\Omega_g$, and $\tau=0.32$ s. A pose step loads its arm, so the step meets the glassy stiffness and rings: from 100×10 to 125×8 pt at constant volume, $\alpha$ overshoots by 57.6% and stays within 2% of its target after 1.38 s. A step that left the arm alone would overshoot by about a fifth and read as a liquid rather than a gel.

**Sway** $\delta$ is a Zener gel with $\Omega_\infty=10$ and $\Omega_1=6.3$ rad/s ($\Omega_g=11.8$), loss ratio 0.16, and $\tau=0.32$ s. Its target is the pose's lateral offset plus $6\ \mathrm{pt}\times\mathrm{lean}$, where the drive's lean in $[-1,1]$ points toward the window the text will land in; 6 pt is under a third of the speaking body's 20 pt crest spacing. A lean arrives with the jelly's wobble and, held, creeps rather than snaps.

**Skew and neck** are critically damped at 12 rad/s. A lopsided lurch and a pinched waist are poses, not wobbles.

A pose step moves the reference configuration of each gel coordinate and loads its arm by $-\Omega_1^2\Delta$, as in the [exact propagator](#exact-propagator). The panel's own acceleration is a force instead. With $a_t$ and $a_n$ its tangential and normal components in pt/s², each clamped to ±40,000 so that a panel that jumps sloshes the mercury rather than teleporting it, the drive pushes

$$
 f_\delta=-0.03\,a_t,
 \qquad
 f_\alpha=-1.4\times10^{-3}\ \mathrm{pt^{-1}}\,a_n.
$$

The sway feels 3% of the panel's acceleration, the inertia of a liquid carried in a moving cup, and a positive normal acceleration shortens and thickens the body at constant volume. Each force shifts only its coordinate's rubbery equilibrium, by $f/\Omega_\infty^2$, exactly for a piecewise-constant force. It never touches the stress, so nothing is left behind once the panel stops.

### Limits

The coordinates stay inside

$$
 0\le V\le L_{max}H_w,
 \qquad
 \ln V-2\ln H_w\le\alpha\le2\ln L_{max}-\ln V,
$$

$$
 |\delta|\le\min\left(12,\ \frac{L_{max}-L}{2}\right),
 \qquad
 |\mathrm{skew}|\le0.6,
 \qquad
 0\le\mathrm{neck}\le0.85,
$$

with $L_{max}$ the longest body the layout can draw, the island's 168 pt or the collar's whole spine, and $H_w=13.24$ pt the [height wall](#stations-and-mean-envelope). At volume $V>0$ the aspect walls are exactly $L\le L_{max}$ and $H\le H_w$. The 12 pt sway wall holds the lurch's 8 pt and a full lean's 6 pt to 12 together, so a lurch stays the lean of a body that is still where it was. The second sway bound is the ends of the body's track. Every body rides the same $L_{max}$ of spine, centred on its rest centre, so $|\delta|+L/2\le L_{max}/2$ keeps each end within the longest body's, and the margin kept for that body's round end holds every body's. A pose's sway target is held to the pose's length and the body's sway to the length it has: the 160 pt speaking body on the island can sway 4 pt either way, while the 185×32 pt collar's 356 pt spine leaves every speaking body the whole 12.

Every target is first projected into these bounds, by `reset(to:limits:)` exactly as by `step`, so no spring is ever anchored past a wall and a reset lands where a step holds the pose: a speaking island body asked for a full 6 pt lean starts at its track's end, 4 pt out. A pose anchored beyond a wall would wind the arm up while the body waited at the wall, then fling the body back by the whole anchor displacement when the pose returned: a 30 pt sway target held against the 12 pt wall would send the body into the opposite wall. Each bound is then Moreau's inelastic wall for whatever momentum still reaches it. The coordinate is projected onto the wall and its outward velocity removed, so it slides along the wall instead of being re-clamped every substep, which would read as a stutter. A gel coordinate also gives up the outward part of its arm's push $-\sigma$, so its own stored stress never holds the body against a wall.

### Swallow and emergence

An idle target is an outflow through the notch into a reservoir $R^2$ below empty, with $R=H_{max}=17$ pt. Aimed at empty itself, the critically damped volume would only approach it: the island's speaking body would still hold 26 pt² at 0.6 s and need 0.97 s to fall below 1 pt². An orifice drains in finite time, so the outflow aims past empty and the Moreau floor stops it exactly at $V=0$. From rest at volume $V$ the exact law gives $V(t)=(V+R^2)(1+\omega_Vt)e^{-\omega_Vt}-R^2$, so the body is empty from the first substep, $t=nh$, at which

$$
 (1+\omega_Vt)\,e^{-\omega_Vt}\le\frac{R^2}{V+R^2}.
$$

The island's 160 × 9.5 pt speaking body empties on the 40th substep, 0.333 s into the swallow; the largest island body, 168 × 13.24 pt, on the 45th, 0.375 s; and the largest collar body, the 220×38 pt housing's whole 401 pt spine at 13.24 pt, on the 57th, 0.475 s. With no target shape, the aspect holds, so the body keeps its proportions while it drains.

The reservoir is the containment ceiling, not the height wall. How deep a body may be is the crests' business; how fast it swallows is not. A reservoir that shrank with the wall would slow every swallow: the island's speaking body would empty on the 47th substep, 0.392 s, and on the 33rd, 0.275 s, under Reduce Motion.

An empty body has no shape to remember. While $V=0$, its aspect, sway, skew, and neck sit on their targets with no stress, so the body grows out of the notch already in its pose. Velocities are kept, so an arrival kick handed to an empty body becomes the first motion of the mercury that emerges.

`MercuryEngine`'s first live frame starts the body empty, and it grows from nothing into its pose: its volume rises monotonically and never past the pose, and the speaking body is within 2% of its length after 0.6 s. Harness renders and Reduce Motion start the body at rest on its pose instead, at exactly the pose's length and half-height.

### Reduce Motion

Under Reduce Motion the body shape keeps every destination and reaches each once. What a reader sees is $L$ and $H$, and a volume and an aspect that each settle monotonically at their different rates can still compose an $L=\sqrt{Ve^{\alpha}}$ that turns back. Reduce Motion therefore moves $L$ and $H$ themselves, each critically damped at $\omega_V=10$ rad/s toward the pose inside $0\le L\le L_{max}$ and $0\le H\le H_w$, so from rest both are monotone by construction and a pose change carries no squash or stretch. Only the area may turn back: where one extent shrinks while the other grows, $LH$ swells by up to 7% of the larger pose's area on the ladder. $V$, $\alpha$, and their rates are read back off the two with the aspect's arm unloaded, so the gel laws carry on with the same motion when Reduce Motion ends.

Critical damping is monotone from rest, not from every motion, and Reduce Motion can be turned on while the gel is still swinging. It takes over whenever it has no rates of its own: after the gel has carried the body, after a kick has landed, and after a reset. With offset $x$ from the target and $s=\dot x+\omega x$, the law moves as

$$
 x(t)=e^{-\omega t}(x+s\,t),
 \qquad
 \dot x(t)=e^{-\omega t}(\dot x-\omega t\,s).
$$

It crosses the target at $t=-x/s$, which lies ahead exactly when the rate toward the target exceeds $\omega|x|$, and a rate pointing away first carries the body further off. The monotone set is therefore $\dot x$ between 0 and $-\omega x$, that is $\dot x\,s\le0$, and the law never leaves it:

$$
 \dot x(t)\,s(t)=e^{-2\omega t}\bigl(\dot x\,s-\omega t\,s^2\bigr)\le0.
$$

So on taking over, Reduce Motion projects each rate once into its law's monotone set: $\dot L=\dot V/2H+L\dot\alpha/2$ and $\dot H=\dot V/2L-H\dot\alpha/2$, read off the volume and the aspect, and the sway's rate, each against its own target. Against a fixed target that one projection serves every later substep, so wherever Reduce Motion finds the body, it goes straight to its pose: from rest by construction, mid-swing by the projection. Across every ordered pair of ladder poses, with Reduce Motion turned on at each substep from 0 to 120 of the gel's transition, the unprojected rates carried 3,906 of 6,776 island runs and 6,835 of 10,890 collar runs past the pose, by up to 26 pt and 57 pt; projected, none passes it.

The projection is made once, on taking over. A pose that changes while Reduce Motion is already moving the body can still carry it past the new pose, by up to 48 pt on a collar sequence the app never makes. The app's own sequences do not: a toggle between listening and speaking only reverses smoothly, and speaking → processing → outcome never overshoots.

A swallow under Reduce Motion drains the extent into the same reservoir at the held aspect: $L$ aims at $-Re^{\alpha/2}$ and $H$ at $-Re^{-\alpha/2}$, so the body keeps its proportions, and both reach zero on the same substep, the first at which $(1+\omega_Vt)e^{-\omega_Vt}\le R/(\sqrt V+R)$: the 30th, 0.250 s, for the island's speaking body and the 37th, 0.308 s, for the largest collar body. A body that reaches the floor along either extent is empty, and an empty body starts from rest: its extent, sway, skew, and neck. The sway is critically damped at its rubbery frequency with its stress zeroed; the panel's acceleration still leans it but never squashes the extent. Gesture and arrival kicks to the body shape are spent without being applied, so they cannot land later either.

### Pose ladder

`MercuryPose` is the only channel from session state to shape: there is no glyph, word, or hue. Each state asks for a length and half-height, a voice drive scale, and, for the outcome gestures, an offset, skew, or neck:

| state | island $L\times H$ (pt) | collar $L\times H$ (pt) | voice | reads as |
| --- | --- | --- | --- | --- |
| warming | 58 × 8.5 | 58 × 8.5 | off | a small calm bead |
| listening | 140 × 9.3 | $(B+1.7C)$ × 8.6 | on | a lip: long, thin, and alive to the voice |
| speaking | 160 × 9.5 | $(B+2C+1.8W)$ × 11.5 | on | the longest live body, deeper than the lip; on the collar it climbs the walls |
| processing | 84 × 12.5 | 84 × 12.5 | off | a held gathered pose, not a working mark |
| copy-only, `gathered` | 70 × 11 | 64 × 12 | off | a squashed bead |
| paste failure, `lurch` | 78 × 11; offset 8 pt; skew 0.4 | as the island | off | a lopsided 70/30 lean |
| error, `collapse` | 92 × 6.6; neck 0.7 | $0.8B$ × 6.6; neck 0.7 | off | two drips joined by a thread |

Warming is a bead rather than a flat capsule because the state it reports, capture requested with no audio yet, held for 1,422 ms on a cold AirPods Max link, and a body that looks like a listening body during it is how a user speaks into the hole.

The speaking body is deliberately not the tallest it could be. The containment budget is $\ln(H_{max}/H_0)$, so every point of mean thickness is amplitude the crests cannot have; at 11.5 pt the budget is 0.39, and the body necks and swells the way a driven liquid ridge does. The collar's speaking body keeps that depth: shallower speaking collars darkened their rooms' medians below the screen's 0.18 bound. The island's is 9.5 pt, a budget of 0.58, because its raster cost follows the body's area, not its crests. At 11.5 pt its live crests held it against the island's 34 pt height, where a raster cost 0.58–0.63 ms against the 0.55 ms gate; cutting the drive gain from 0.79 to 0.45 moved the cost only from 0.603 to 0.585 ms, and a 10 pt body still cost 0.569 ms. At 9.5 pt it costs 0.527–0.533 ms ([Measured gates](#measured-gates)).

The island's listening lip is 140 × 9.3. In rooms that are one uniform wall but for a few sources, a thin lip's reflections can miss every source, and its 95th percentile then falls short of separating it from a mid-grey ground. Scanning the 4,096-room screen at twelve instants of the crest cycle counts such listening failures:

| island listening lip (pt) | failures over 12 instants |
| --- | ---: |
| 130 × 8 | 21 |
| 130 × 8.6 | 16 |
| 140 × 9.3 | 14 |

A tail of these uniform-room failures remains, about 1.2 per instant across the crest cycle. The benchmark's screen at 600 substeps is the designed single draw from it, and it draws none. The collar's lip is 8.6 pt deep, which brings the darkest room's listening collar from 0.2596 crushed area to 0.234, under the 0.25 bound. On both ladders speaking stays longer and deeper than listening, and warming stays a bead.

The collar measures its ladder along the housing outline: the bottom run $B$ and, per side, the corner $C$, wall $W$, fillet $F$, and ear $E$. Listening lies along the bottom and most of both corners; speaking takes both corners and nine tenths of each wall. `MercuryPoseContext` changes the speaking reach. With the pointer in the menu-bar band, the body gives the walls back, $B+2C$, so no film lies where the user is reaching for a menu or a status item. Over a full-screen app, where the band beside the notch is empty black, it also turns both fillets and runs seven tenths along each ear, $B+2C+1.8W+2F+1.4E$. Around the 185×32 pt housing, listening is 196 pt long and speaking 227 pt, 202 pt with the pointer in the band, or 320 pt over a full-screen app, of the spine's 356 pt. The collapse spans eight tenths of the bottom so both drips hang under the housing, and the copy-only bead is a drop under the notch; warming, processing, and the lurch keep the island's lengths, which already fit inside the bottom run.

`MercurySimulation.Drive.target(for:reduceMotion:)` is the one place a live drive is built: the pose on the ladder its layout climbs, the meter buffer, and $L_{max}$.

### Gestures and arrivals

An outcome gesture is its pose plus one-shot kicks, latched once when the pose's gesture changes:

- `gathered`, copy-only delivery: an aspect kick of $-2.0$ s⁻¹, so the bead squashes and jiggles back.
- `lurch`, paste failure: skew 0.4 and an 8 pt lateral offset, a sway kick of $+60$ pt/s that throws the body toward its offset, past it, and back, and a 1.1 s⁻¹ kick to the contact-line fundamental.
- `collapse`, error: neck 0.7, an aspect kick of $+1.5$ s⁻¹ that stretches the body as it thins into its pinched waist, and a 1.0 s⁻¹ kick to the varicose fundamental.

A reset into a pose that already carries its gesture spends the gesture instead of kicking it. Reduce Motion spends the body-shape kicks without applying them, but the mode kicks still fire, because a gesture carries information.

An arrival is the kick a body takes as it emerges on the display it was handed to: a `MercuryArrival` token with a sway rate along the spine's left-to-right traversal, away from the side the body came from, and an aspect rate, negative for a landing squash. Arrival ids only grow. The simulation keeps the highest id it has applied and kicks only for a higher one, so the same arrival can accompany every frame of an emergence and the body still feels one kick, and an older token handed over again after a newer one never kicks. A reset forgets them all: an emerging body has applied none and takes its arrival on its first advance, while a body reset at rest counts the drive's own arrival as applied, so that arrival is spent.

## Exact containment on the drawn envelope

The body must never escape its canvas, and on the collar it must stay a film inside the menu-bar band. A componentwise amplitude clamp was rejected because it protects against a worst-case phase alignment the eight-mode field does not realise and visibly suppresses the liquid.

At each sampled station $j$, the upper edge is

$$
 y_{T,j}=H_0G_{s,j} e^{\theta_{T,j}}.
$$

The exact admissible log displacement is

$$
 \theta_{T,j}\le
 \log\frac{H_{max}}{H_0G_{s,j}},
$$

and likewise for the lower edge. The containment gauge is the worst normalized violation over both edges and all 97 stations. If the gauge $\gamma>1$, every mode amplitude is retracted by $1/\gamma$. Because $\theta$ is linear in the complex amplitudes, the binding station lands exactly on the envelope. The [height wall](#stations-and-mean-envelope) leaves every station a bound of at least 0.125, so no bound is ever zero or negative. The gauge skips a station whose bound is not positive, which the wall never allows: a mean envelope already at the ceiling admits no crest, and erasing every mode would leave it standing where it is.

Outward radial velocity is removed while tangential velocity survives, and the arm's push $-\sigma$ gives up its outward part too, so stress a mode stored on its way into the boundary cannot press it straight back out through it. This is Moreau-style inelastic contact: the state slides along the constraint instead of striking it on every frame. One scalar rescales both mode families, so containment cannot silently turn an independent two-edge body back into a pill.

The gauge bounds the untapered edges, $y_T\le H_{max}$ and $y_B\ge-H_{max}$ with $H_{max}=17$ pt, and the field scales both by $\Lambda(s)\le1$. The drawn body therefore reaches at most $\Lambda(s)H_{max}$ from the spine: 17 pt on the island and under the notch, 3.5 pt on the walls, fillets, and ears. Each canvas holds that reach. The island's canvas is ±17 pt about its spine and ±98 pt along it. Its bodies ride a 168 pt track that ends 84 pt from the centre, and a round end reaches past the track by its own half-thickness: at rest every pose stays inside the envelope's ±90 pt, but the speaking body at full lean or under the hardest drag rounds off up to 93.5 pt out, and 94 pt on an adversarial meter. The collar's canvas holds the 17 pt chin plus a 3 pt margin for its bleed, and 4 pt past each ear's end for a film-thick round end and its coverage ramp. The field's bounding box is intersected with the canvas, which is the absolute envelope: the bleed keeps the coverage ramp whole and never carries the body past the canvas.

## One scalar field for pixels and interaction

`MercuryField` lays the simulated edges on the spine once, and every reader interpolates that one table. Each station keeps its untapered radius and centre

$$
 r_0=\frac{y_T-y_B}{2},\qquad c_0=\frac{y_T+y_B}{2},
$$

and their finite differences per station, central inside and one-sided at the ends. All four interpolate linearly between stations; the interpolated differences, scaled by 96, are $\partial_a r_0$ and $\partial_a c_0$, so the normal stays continuous across station boundaries.

A point $\mathbf x$ is read through its chart. Its material coordinate is

$$
 a=\operatorname{clamp}\left(\frac{s-\bar s}{L}+\frac12,\,0,\,1\right),
$$

and the taper is evaluated at the point's own arc length rather than at the stations:

$$
 r=\Lambda(s)\,r_0(a),\qquad c=\Lambda(s)\,c_0(a),
$$

$$
 r_s=\Lambda'(s)\,r_0+\Lambda(s)\frac{\partial_a r_0}{L},\qquad
 c_s=\Lambda'(s)\,c_0+\Lambda(s)\frac{\partial_a c_0}{L}.
$$

A corner's taper turns from chin to film over 8.6–9.8 pt of arc, while a collar body's stations sit up to about 4 pt apart. Tapering the stations instead would facet the outline across every corner, and the normal's smoothing term, its departure from the drawn outline's own slope, would reach 0.2–0.32 there.

Inside the span, $|s-\bar s|\le L/2$, the signed field is

$$
 \phi=r-|n-c|.
$$

With $\nabla s=\mathbf T/J$ and $\nabla n=\mathbf N$, its gradient and the radius gradient the crown reads are

$$
 \nabla\phi=\frac{r_s\pm c_s}{J}\,\mathbf T\mp\mathbf N,
 \qquad
 \nabla r=\frac{r_s}{J}\,\mathbf T,
 \qquad
 \pm=\operatorname{sgn}(n-c).
$$

The metric belongs in the normal. Offset curves around a convex corner are longer than the corner by $1+\kappa n$, so a crest wrapped around it is stretched and its slope along the body falls by exactly that factor; around a concave fillet they are shorter by $1-|\kappa|n$, and the slope steepens. Using $\mathbf T$ alone would tilt every normal on the curved primitives by the wrong amount. With $J$, the normal is the true surface normal, and it is continuous wherever $\kappa$ is: everywhere on the G³ spine, across every join included ([Eased bends](#eased-bends)).

Beyond either end of the span the field is the exact Euclidean round cap

$$
 \phi=r_e-\lVert\mathbf x-P_e\rVert,
 \qquad
 P_e=\Gamma(s_e)+c_e\,\mathbf N(s_e),
$$

where $\Gamma(s_e)$ is the spine point at the end's arc length, and $r_e$ and $c_e$ are the end station's values tapered by $\Lambda(s_e)$. Its gradient is $-(\mathbf x-P_e)/\lVert\mathbf x-P_e\rVert$, and $\nabla r=0$. Both ends are full rounds with no cut, needle, or separately generated cap to seam.

On the island every chart quantity is exact: $s=x+98$, $n=y$, $\mathbf T=\hat x$, $\mathbf N=\hat y$, $J=1$, $\Lambda\equiv1$, and $\Lambda'\equiv0$, and the cap offset is taken in the chart itself. The field there is, bit for bit, the straight ribbon

$$
 \phi(x,y)=r(x)-|y-c(x)|,
 \qquad
 \phi_{cap}(x,y)=r-\sqrt{(x-x_c)^2+(y-c)^2}.
$$

Positive values are inside. The same `MercuryField` evaluation decides:

- pixel coverage;
- panel drag eligibility;
- open-hand cursor routing.

This is a structural safety property, not a visual approximation. Transparent corners of the panel cannot swallow a click, and where the spine has no chart there is no body: nothing is drawn and nothing is hit. `MercuryHitRegion` converts panel points into the canvas of the layout last drawn and never claims a point in that layout's menu-bar band, `OverlayDisplay.bandHeight` deep. Menus, menu titles, and status items own that strip, so the collar's film there is drawn but never hit. The island's band is empty.

Coverage is analytic first-order antialiasing:

$$
 \alpha=\operatorname{clamp}
 \left(\frac12+\frac{\phi}{\|\nabla\phi\|p},0,1\right),
$$

where $p$ is one device pixel in points. On the collar, the walls, corners, and bottom run border the housing. There coverage is also multiplied by $\operatorname{clamp}(\tfrac12+d/p,0,1)$, the same ramp on the chart's `rimDistance` $d$, the distance outside the housing's circular outline, so the hardware edge is antialiased instead of drawn by pixel centre. On the walls and the bottom $d=n$. On a corner it is not: the eased spine stands up to $g$ outside the circular rim, and a pixel centred in that sliver lies inside the body and outside the hardware. The ears and fillets meet the screen's top edge, which is already the canvas edge.

The rasterizer charts every pixel centre. On a horizontal run $s$ depends on $x$ alone, so each pixel column memoizes the station sample at its arc length and the rest of the column reuses it; the memo caches `stationSample(at:)` and is never a second evaluator. A conservative mask skips pixels the body cannot cover. Each frame it marks, row by row, the 8-pixel column blocks touched by a box around every piece of the body: each station interval, split at the spine's primitive joins, and both caps, each grown by its own provable coverage reach, half a pixel times the bound on $\|\nabla\phi\|$ over the piece, plus one pixel. A piece that reaches a concave fillet contributes the whole $\rho_e$ square instead, because $\|\nabla\phi\|$ has no bound near the fillet's centre. A piece on a convex corner starts its normal range at $-g$, to hold the sliver its chart reaches below the spine, and divides its climb along the body by the least metric that sliver reaches against the plateau's curvature, $1-g/R_p=0.94443$ (`leastCornerMetric`), before it bounds $\|\nabla\phi\|$. The marked blocks are visited in the same row-major order as a loop over every canvas pixel, so the image, and even the calibration's radiance sample sequence, is bit-identical to that loop.

A chart depends on the spine and the pixel alone, never on the body, so the rasterizer keeps the charts of the pixels around the collar's four bends from frame to frame: each convex corner's quadrant, out to 22 pt to hold the 17 pt chin and its coverage ramp, and each fillet's square. Only those charts are dear, a plateau's arctangent or a ramp's Newton steps; every other pixel is charted afresh in a few multiplies. The kept charts are forgotten whenever the spine, the canvas, or the scale changes, and each is bit-identical to a fresh one. Without them the speaking collar's raster costs 0.059 ms more.

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

Across the island's 196×34 pt canvas $q<0.0052$; across the widest collar canvas, 349×58 pt, $q<0.0163$. Voiceour uses

$$
 (1+q)^{-1/2}\approx
 1-\frac12q+\frac38q^2-\frac5{16}q^3.
$$

The series alternates, so its first omitted term, $\tfrac{35}{128}q^4$, bounds the direction error: about $2\times10^{-10}$ on the island and $1.9\times10^{-8}$ on the widest collar canvas, far below one 8-bit code value. Dense tests check both canvases against the exact normalization.

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

Thirty percent of the room is neutral bounce. Source power is normalized so the other 70% is seed-independent. Local chroma of up to 6.5% is built by projecting a random RGB opponent onto the Rec.709 luminance-null plane

$$
 w=(0.2126,0.7152,0.0722),
$$

$$
 c'=c-w\frac{c\cdot w}{w\cdot w}.
$$

The source coefficients are power-centred before tinting. Individual reflections can therefore carry colour while the whole room remains neutral.

At 6.5% the tint is visible in reflections and keeps every body under the benchmark's 0.12 local-saturation and 0.06 whole-body-cast bounds. At 7%, the collar corpus's seed-20 room cast its collars past 0.06 whatever their pose: the listening collar 0.0627–0.0649 over lip lengths from $B+1.2C$ to $B+2C$ and depths of 7–9 pt, the speaking collar 0.0602–0.0604. At 6.5% the worst collar cast is 0.0590, and the worst over the 4,096-room island screen 0.0406. The tint carries no luminance, so the screen's median, highlight, ground, and crushed verdicts are the same at either strength.

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

across both listening and speaking bodies for the session's actual room and body seed, laid out as the layout it lights draws them. Each body is placed at rest on its pose and advanced 180 substeps on its meter buffer held still, the syllable for speaking and the quiet room for listening, and every fourth pixel more than half covered enters the pool. The layout matters as much as the pose: a collar shows only the outer half of a chin and walls, which sweeps a different part of the room than the island's whole crown, so a collar is lit by its own response. `MercuryEngine` meters the first layout a session draws and meters again, in the same room, when a frame arrives on another layout, so the solve is paid once per layout and never per frame. The response takes scene anchors $s_m=p50$ and $s_h=p98$ and maps them to

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

Presentation follows the display because the visible defect of a slow raster is zero-order hold, not aliasing. The motion that carries information is slow: the voice advects mode $m$ at $1.14m$ Hz, at most 9.1 Hz, and the body shape rings at 1.9–2.6 Hz. The gel's stiffness lifts the free modes higher, nearly harmonically, to 16.6 Hz at the island speaking body's eighth mode and 46 Hz at the 58 pt warming bead's, still below the 60 Hz Nyquist limit of 120 Hz presentation; their autonomous amplitude falls as $m^{-3/2}$, so no free mode above 15 Hz moves the edge by more than 0.12 pt rms. Even 30 fps would satisfy Nyquist for the slow motion, but holding high-contrast specular bands for 33.3 ms under smooth pursuit still makes a stable body look quantized.

`NSView.displayLink(target:selector:)` is tied to the display containing the view, and AppKit stops callbacks while the view is hidden or off-display. `MercurySurfaceView` requests

$$
 f_p=\min(f_{screen,max},120),
$$

or 60 fps from a screen that reports no maximum, and rebuilds the link whenever its window changes screen.

The physics step never changes. `MercuryClock` counts fixed substeps of $h=1/120$ s from an epoch $t_0$: the `targetTimestamp` of the first callback, which presents nothing. A frame that will be shown at $t$ presents the substep nearest to it,

$$
 \nu(t)=\left\lfloor\frac{t-t_0}{h}+\frac12\right\rfloor,
$$

advancing by $\nu(t)-\nu_p$ substeps from the $\nu_p$ already presented, or by none when that difference is not positive. Every frame is counted from the one epoch rather than accumulated from callback intervals, so each wall-clock second holds exactly 120 substeps at any cadence: one per frame at 120 Hz, two at 60 Hz, the cycle 2, 1, 2, 1, 2 at 75 Hz, two or three at 48 Hz, and never more than one at 144 Hz. An accumulated remainder would round a little on every frame and would have to be discarded whenever the link is rebuilt, losing part of a substep at each display hand-off. The clock reads only target timestamps, never a callback interval or the hardware-reported duration, because the preferred callback rate can differ from panel refresh.

Rounding, not flooring, is load-bearing. The epoch is a real frame's target, so at an integer cadence every later frame lands exactly on a substep boundary, where a floor has no margin. Measured on the development Mac, a floor broke both ways: three and a half days after boot, the rounding of real `CACurrentMediaTime` values alone turned two 120 Hz frames in three into 0s and 2s, and ±10 µs of vsync jitter does the same at any uptime. Rounding centres each frame in a ±4.17 ms cell, so the presented body is never more than half a substep from the moment it is shown.

More than four substeps due at once, `MercuryMetrics.maxSubstepsPerFrame`, means the link stalled, the panel was hidden, or a new display's link started late. The clock then presents the cap and re-anchors its epoch on the current frame:

$$
 \nu_p\leftarrow\nu_p+4,\qquad t_0\leftarrow t-\nu_p\,h.
$$

The frame sits exactly on the substep it presents, so an old body resumes instead of fast-forwarding through unseen motion, and the new cadence starts centred in its cells.

A display hand-off below the cap needs the same centring. The new display's vsyncs keep their own phase: counted on the old grid, a 60 Hz display half a substep off it puts every frame on a rounding boundary, where ±20 µs of jitter turns its steady 2, 2, 2 into 1, 3, 1, 3 for as long as the panel stays there. The first callback of every rebuilt link therefore calls `rephase` instead of `steps`. It presents exactly the substeps `steps` would, then moves the epoch so that frame sits on the substep it rounds to,

$$
 t_0\leftarrow t-\nu(t)\,h,
$$

a move of at most half a substep: the frame's own rounding. Later frames count from it, so the hand-off neither skips a substep nor presents one twice, and the new cadence starts centred in its cells.

`MercurySurfaceView` owns one clock and never resets it, even when the link is rebuilt for another display. A new link whose first target precedes the last presented substep re-phases onto the substep that target rounds to, not the last one presented, and presents nothing until time catches up. Past the cap, `rephase` handles a stall exactly as `steps` does. A non-finite timestamp presents nothing and leaves the epoch untouched.

The renderer writes `CGImage` directly to `CALayer.contents` with implicit actions disabled. No frame index, timestamp, or image is published into SwiftUI. `MercuryEngine` returns the same image identity when committed geometry, appearance, and layout have not changed, avoiding a layer upload on a zero-step or Reduce Motion callback.

A native probe on the development M4 Pro measured a 120 Hz screen at exactly 121 callbacks over one second: `120.0 Hz`, with both target interval and reported duration at `1/120 s`.

## Calibration instead of magic gains

Three look-defining values are solved against production geometry and optics rather than typed in:

1. Voice drive gain is solved by proportional iteration, with the contact line off, until the median speaking crest prominence under live-like speech is `5.0 pt`.
2. Contact-line gain is then bisected against that drive, in the quiet room held still, until the upper/lower mirror correlation is near zero.
3. Every session's display response solves its own p50/p98 room anchors on the layout it lights ([Bounded display response](#bounded-display-response)).

Geometry calibration differences a driven run and a zero-drive run from the same seed, on the same meter, with Reduce Motion enabled. Because the mode law is linear below containment, static asymmetry and stochastic decoration cancel exactly; the solve measures voice contribution only. The zero-drive run has no gain to try, so it runs once per seed and its frames are kept. Each run resets at rest on the island's canonical pose, which under Reduce Motion the body shape never leaves, then settles 180 substeps. The modes start at the voice's equilibrium of that instant and the voice moves on at once; the gel's slowest answer is the arm's creep, 2.1 s⁻¹ for the speaking fundamental, and after 1.5 s it is gone. Over one crest period on a buffer held still, the prominence after 180 substeps agrees with that after 1,440 to 0.01%; under live speech, the median prominence pooled over 48 seeds shows no trend from the first second after the reset on.

Both solves hear `MercurySpeechMeter`, as the benchmark's bodies do. It feeds a real `RecordingOverlayModel` through `record(_:)` and rebuilds the drive with `Drive.target(for:reduceMotion:)` at each new level, so every measurement reaches its pose through the voice-activity hysteresis, as a session does. A level falls due every 40 ms, $24/5$ substeps, so the runs between levels are 5, 5, 5, 5, and 4 substeps. A speaking meter walks the syllable buffer in a loop from a seeded first level, moving on by 0, 1, or 2 levels with equal odds, drawn from its own noise stream, `MercuryNoiseStream.speechMeter` = 9. It keeps the syllable's range, 0.08–0.88, its mean, and its spread, never settles into a period, and its floor stays above the release level, so the speaking pose holds. A quiet meter hears the quiet room, every level at or below the release level, held still.

The drive is solved under live speech because live speech sets the crest a speaking user sees. A buffer held still keeps advecting, and its band-limited extension is periodic in $2L$: for half of every 0.88 s the body carries the buffer, thick and busy, and for the other half the extension's trough, thin and smooth, and the quasi-static gel draws both. At one gain the live crests stand 14% above the frozen ones, a median of 4.96 against 4.34 pt pooled over 6 seeds × 28 s. Live speech never repeats, so no window spans a period of it; the solve measures two seeds for 5 s each, a frame every 6 substeps, which is long enough that where the window starts stops mattering. Over six window starts from 1.5 s to 9 s after the reset, the solved gain moves by 2% (one standard deviation), and over six pairs of other seeds by 3%. Proportional iteration affords that window. Below the gauge the voice's amplitudes are linear in the gain, and the drawn edge's exponential and the gauge bend the prominence away from proportional by only a few percent, so scaling the gain by target over measured, from a unit gain, converges geometrically: four to six measurements land within 0.1% of the target and agree with the bisected root to 0.04%, where bisection takes twenty. Bisected, this window alone took 190 ms.

The contact line is solved in the quiet room held still. Edge independence is a structural property of the law, solved at the listening pose, which speech never reaches, and a stationary periodic input is the right probe for it. Every mode advects through whole turns in $2\times0.44$ s, so `MercuryCalibration` derives 53 frames of two substeps from the meter's buffer period, spanning 0.88 s to within 0.4 of a substep, and the correlation cannot depend on where in the period the window starts. A partial period would: on a buffer held still, a 48-frame window leaves out an eleventh of the period, and which eleventh moves the median speaking prominence at one gain between 4.3 and 5.2 pt. Played on a loop instead, the quiet room's correlation is already −0.193 at zero contact line, so the solve would have no root and return a degenerate zero.

The solve gives a drive gain of 0.7862 and a contact-line gain of 0.0246, which `make ui-mercury` prints. The contact line also moves the top edge, so with both gains the median crest prominence under live speech is 5.2483 pt, and the mirror correlation in the quiet room rounds to −0.0000. `MercuryCalibrationTests` holds the prominence within 10% of its target and the correlation at or below 0.2.

The one-time calibration is warmed in `VoiceourApp.init` and takes 113–125 ms on the development M4 Pro. Current gates require launch calibration below 200 ms and first generated room plus first raster below 25 ms.

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

`make ui-mercury-bench` is permanent and production-backed, and `make check` runs it. The hard-gate column is the contract `MercuryChromeBenchmark` enforces. The result column is the measurement of 2026-10-30 on the development M4 Pro, four runs on an idle machine, with the range where the runs differ; rerun the target for current values, which it writes to `.build/ui-harness/mercury/benchmark.json`.

| measurement | result | hard gate |
| --- | ---: | ---: |
| generated rooms | 4,096/4,096 pass | zero failures |
| near-white body area | 0.0016 | ≤0.02 |
| reflected-direction coverage | 3.6983 sr | ≥2.0 sr |
| 30 s median luminance drift | 0.8976 stops | ≤1.0 stop |
| launch calibration | 113–125 ms | ≤200 ms |
| cold room + first raster | 9.2–9.4 ms | ≤25 ms |
| raster p50 / p99 | 0.527–0.533 / 0.543–0.582 ms | ≤0.55 / 0.70 ms |
| raster CPU at 120 Hz | 0.0630–0.0639 core | ≤0.066 core |
| engine + layer p50 / p99 | 0.533–0.550 / 0.586–0.599 ms | ≤0.65 / 0.85 ms |
| engine + layer CPU at 120 Hz | 0.0633–0.0654 core | ≤0.08 core |
| collar sessions | 64/64 pass | zero failures |
| collar near-white area, standard / Increase Contrast | 0.0039 / 0.0147 | ≤0.02 |
| collar raster p50 / p99 | 0.476–0.485 / 0.499–0.529 ms | ≤0.55 / 0.70 ms |
| collar raster CPU at 120 Hz | 0.0571–0.0576 core | ≤0.066 core |

A seed fails the 4,096-seed distribution screen when, for either the listening or the speaking reflection manifold, mapped luminance has a median outside `[0.18, 0.55]`, a p95 outside `[0.60, 0.92]`, a p05–p95 span below `0.30`, or less than `1.5` contrast ratio against any of the near-black, mid-grey, and near-white grounds (`0.075`, `0.45`, `0.95`); it also fails when crushed-black area exceeds `0.25`, near-ceiling area `0.02`, p95 local saturation `0.12`, or whole-body colour cast `0.06`. The 64-seed raster corpus additionally fails an Increase Contrast near-white area above `0.02`.

Every body the bench measures is placed at rest on its pose and settled 600 substeps on a `MercurySpeechMeter`, as calibration's are: a speaking body hears live-like speech, a new level every 40 ms, and a listening body hears the quiet room held still. The measurements are taken at those 600 substeps and, for the motion series, over 30 s more at a sample every 75 ms. A speaking buffer held still would measure its own phase rather than what a speaking user sees: it keeps advecting through a thick half and a thin one, and at 600 substeps a frozen speaking body sat at the 5th percentile of its own series, so the bench would time a thin body.

The bench also screens a 64-seed collar corpus around the 185×32 pt housing, on its 314×52 pt canvas, with the same near-white, distribution, and raster gates. Each seed is a session: its own listening and speaking collar bodies, the speaking one hearing that seed's own speech, settled 600 substeps in its own room and lit through the response `MercuryCalibration` meters on that seed's collar bodies, as the engine lights them. The collar shows only its outer half, below and beside the housing, so it reflects a different part of the room than the island's whole crown, and a response metered on the island's body is not the collar's. Every seed must pass the distribution screen's per-seed bounds above, applied to the shipping raster's own samples; near-white area must stay at or below `0.02` under both contrast settings; and the speaking collar, timed on the performance screen's seed and room, must meet the island's raster p50, p99, and 120 Hz CPU gates.

The engine-and-layer timing first plays the emergence out untimed, 90 frames of one substep each, 0.75 s, after which the body holds 99.5% of its pose's volume and 99.8% of its length, so it times the speaking body in its pose rather than its growth from nothing. The meter ticks between frames, as a level reaches the model between two display-link callbacks, so the engine meets each new buffer inside the next frame as one voice refresh. The raster timings, island and collar, draw a body placed at rest on its pose, which never emerges.

The visual companion is `make ui-mercury`, which writes the contact sheets listed in [ui-harness.md](ui-harness.md#artifacts-and-goldens) under `.build/ui-harness/mercury/`. It is an inspection tool, not a gate.

The relevant automated contracts include:

- `MercurySimulationTests`: replay and batch independence through emergence, lean, frame forcing, and an arrival; distinct seeds; containment under adversarial meters and at the widest skew on the deepest body; a body at its height wall that keeps its crests, reaching 13.24 pt and never passing it; time-averaged edge independence on live and still poses, with the contact line lowering the mirror correlation; Reduce Motion stillness; one-shot outcome impulses; distinct poses, speaking longer and deeper than listening; emergence from nothing; gesture wobble that Reduce Motion removes; the skew's area share and the neck's unbroken waist; a lean inside the sway wall, and the speaking island body stopped at its track's end; one kick per arrival token, and an older token that never kicks again; the collar ladder and its drive limits;
- `MercuryGelTests`: the propagator as the identity at zero step and a semigroup under doubling; the arm-off block against the closed-form damped oscillator; the stationary covariance against the Lyapunov equation and an impulse-response sum; a struck fundamental that rings and a held one that remembers how long it was held; positive, finite modal parameters across the modal range; a zero state that stays zero; batch independence;
- `MercuryBodyShapeTests`: an aspect step that rings and settles at constant volume; Reduce Motion taking every rung of the island and collar ladders straight to every other, emergence and swallow included, whether it is on from the start or turned on up to 60 gel substeps into the transition, with length, half-height, sway, skew, and neck each monotone; volume without overshoot; `L·H = V` through wobble, kicks, forcing, and a swallow; adversarial drives that never leave the limits on the island or a collar spine; a pose past the sway wall or the track's end equal to the pose at it; the sway stopped at the island track's ends, with the whole wall left on the collar; a reset that lands where a step holds the pose; a swallow that empties monotonically with and without Reduce Motion; emergence in pose; a pose step that snaps where a force creeps; frame forcing as an exact equilibrium shift; batch independence;
- `MercuryCrownTests`: analytic derivatives, full crown, limb regularization;
- `MercurySpineTests`: the island axis; collar regions, clamped corners, joins with the plateau's exact curvature and a frame that is the curve's own, and mirror symmetry; eased bends whose curvature is continuous across every join and ramp hand-over and which keep their circle's footprint, with $S=1.62051\,r$, $\kappa_pr=1.14038$, and a rim gap of $0.04873\,r$; `rimDistance` as the distance outside the circular housing; ramp feet within four Newton steps; chart round trips, the brute-force nearest point against a resampled outline whose eased bends are integrated by Simpson's rule from their curvature profile alone, the curvilinear metric, and no chart exactly inside the housing and above the screen; unique fillet offsets; ears continued past their ends; one station per column on horizontal runs; taper plateaus, bounds, C¹ continuity, and analytic slope; a film-only upper band;
- `MercuryFieldTests`: pixel/hit identity on the island and both fixture collars; the island bit for bit as the closed-form straight ribbon; island containment; no island body reaching either end of its 196 pt canvas at full lean, under the hardest drag, or on adversarial meters; the wider island canvas adding only transparent margins, byte for byte and metered sample for sample; one connected body; the hit region's panel-to-field conversion; one evaluation behind value, gradient, and sample; the analytic gradient against central differences on every collar primitive and both caps; a gradient continuous across every join; housing exclusion; a film-only menu-bar band; housing-rim antialiasing; the sparse raster against the full loop, with covered pixels in the rim sliver on both collars;
- `MercuryEnvironmentTests`: positivity, seed replay, power conservation, chroma neutrality, octahedral seam continuity;
- `MercurySpectralTests`: colour-matching and D65 tables against their published integrals and chromaticity, white mapping, sampled-constant provenance, neutral normal incidence, complex-amplitude Fresnel cross-check;
- `MercuryDisplayResponseTests`: anchor solve, monotonicity, unreachable ceiling, Rec.709 gamut handling;
- `MercuryPresentationPerformanceTests`: Fresnel/OETF/response oracle error, view approximation on the island and the widest collar canvas, octahedral round trip, 60/75/120/144 Hz presentation rate;
- `MercuryClockTests`: epoch anchoring; exactly 120 substeps per second at 48, 60, 75, 120, and 144 Hz, with each frame's share; exact counts from 24 MHz tick timestamps with ±20 µs of jitter at 3.5 and 30 days of uptime; the stall cap and re-anchor through `steps` or `rephase`; display hand-offs that drop and repeat nothing; a hand-off half a substep off the old grid that stays 2, 2, 2 instead of 1, 3, 1, 3; every hand-off phase in thousandths of a substep under three kinds of ±20 µs jitter onto 120, 60, and 75 Hz, each re-phasing as `steps` would count, then holding the new display's own cadence within a substep of elapsed time; new links that start behind the last presented substep; non-finite timestamps through either entry point;
- `MercuryEngineTests`: reseeding, duplicate image identity, appearance reraster, collar frames sized to their canvas with no pixel inside the housing, the hit region answering in the layout last drawn, lighting metered on the layout it lights and kept until the layout changes;
- `RecordingOverlayLayoutTests` (in `MercuryEngineTests.swift`): the island's established panel and status frames, with its 196×34 pt canvas 8 pt past the envelope at each end; both fixture collars rebuilt from their housings; the island for notchless, mirrored, and unwearable housings; a collar hit region that rejects the menu-bar band and accepts the chin;
- `MercuryCalibrationTests`: the solved crest prominence under the live meter within 10% of its target; independent voice-driven edges in the quiet room held still, with a nonzero contact-line gain and a mirror correlation at or below 0.2; per-room response median for every `MercuryWorld`; each fixture collar metered on its own bodies to the same median, by a response that is not the island's;
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
| island and collar pose ladders and targets | `Sources/Voiceour/MercuryPose.swift` |
| two-family mode solver, envelope modulators, gestures, arrivals, and containment | `Sources/Voiceour/MercurySimulation.swift` |
| Zener gel law, balanced Padé propagator, and Lyapunov kick variance | `Sources/Voiceour/MercuryGel.swift` |
| body shape: volume, aspect, sway, skew, neck, and their limits | `Sources/Voiceour/MercuryBodyShape.swift` |
| calibrated gains and room metering | `Sources/Voiceour/MercuryCalibration.swift` |
| live-like speech and quiet-room meters for calibration and the benchmark | `Sources/Voiceour/MercurySpeechMeter.swift` |
| spine, eased bends, exact curvilinear chart, and taper | `Sources/Voiceour/MercurySpine.swift` |
| signed silhouette on the spine | `Sources/Voiceour/MercuryField.swift` |
| crown and total derivative | `Sources/Voiceour/MercuryCrown.swift` |
| static generated rooms and octahedral chart | `Sources/Voiceour/MercuryEnvironment.swift` |
| spectral conductor reflectance (CIE 1931 observer, D65, liquid-mercury n and k) | `Sources/Voiceour/MercurySpectral.swift` |
| exact-source optical LUTs | `Sources/Voiceour/MercuryOptics.swift` |
| bounded Naka–Rushton display response | `Sources/Voiceour/MercuryDisplayResponse.swift` |
| production CPU shading | `Sources/Voiceour/MercuryRasterizer.swift` |
| fixed-step engine, image cache, and hit region | `Sources/Voiceour/MercuryRibbon.swift` |
| fixed 120 Hz clock on display target timestamps | `Sources/Voiceour/MercuryClock.swift` |
| frame-rate request, display link, and layer presentation | `Sources/Voiceour/MercuryDisplayLink.swift` |
| island and collar layouts: panel, canvas, status frame, spine, menu-bar band | `Sources/Voiceour/RecordingOverlayLayout.swift` |
| display description: camera housing, menu-bar band, mirror set, frame-rate ceiling | `Sources/Voiceour/RecordingOverlayDisplay.swift` |
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
- Higham, [“The Scaling and Squaring Method for the Matrix Exponential Revisited”](https://doi.org/10.1137/04061101X), *SIAM Journal on Matrix Analysis and Applications* 26(4), 2005, for the [6/6] Padé scaling-and-squaring exponential behind every gel propagator.

## Maintenance rule

This document describes the shipping renderer, not a menu of optional effects. A future change to the field, mode law, body shape, pose ladder, crown, room distribution, optics, response, cadence, or hard benchmark must update this document in the same commit. Raw brainstorm artifacts are disposable. Production code, tests, and the benchmark gates are the enforced contract; this file is their derivation and rationale, and README.md and AGENTS.md remain the authority for what the island must do.
