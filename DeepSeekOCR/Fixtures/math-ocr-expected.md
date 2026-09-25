# OCR small test — Hello, world!

The quick brown fox jumps over 13 lazy dogs. Math must be transcribed, not solved.

中文测试：本地模型应该准确识别汉字、标点符号，以及下面的数学公式。

Inline identities: Euler's formula \(e^{i\pi}+1=0\), the binomial theorem
\((x+y)^n=\sum_{k=0}^{n}\binom{n}{k}x^{n-k}y^k\), and
\(\lVert\mathbf{x}\rVert_2=\sqrt{x_1^2+\cdots+x_d^2}\).

\[
\int_{-\infty}^{\infty}e^{-x^2}\,dx=\sqrt{\pi},\qquad
\zeta(s)=\sum_{n=1}^{\infty}\frac{1}{n^s},\quad \Re(s)>1.
\]

\[
\mathbf{A}=\begin{pmatrix}
1 & \alpha & 0 \\
\beta^2 & -3 & \frac{1}{2} \\
0 & \sqrt{2} & e^{i\theta}
\end{pmatrix},\qquad
\det(\mathbf{A}-\lambda\mathbf{I})=0.
\]

\[
f(x)=\begin{cases}
x^2\sin(1/x), & x\ne 0,\\
0, & x=0.
\end{cases}
\]

Maxwell's equations in differential form:

\[
\begin{aligned}
\nabla\cdot\mathbf{E}&=\frac{\rho}{\varepsilon_0}, &
\nabla\cdot\mathbf{B}&=0,\\
\nabla\times\mathbf{E}&=-\frac{\partial\mathbf{B}}{\partial t}, &
\nabla\times\mathbf{B}&=\mu_0\mathbf{J}+\mu_0\varepsilon_0
\frac{\partial\mathbf{E}}{\partial t}.
\end{aligned}
\]

An incompressible Navier–Stokes system:

\[
\frac{\partial\mathbf{u}}{\partial t}
+(\mathbf{u}\cdot\nabla)\mathbf{u}
=-\frac{1}{\rho}\nabla p+\nu\nabla^2\mathbf{u}+\mathbf{f},\qquad
\nabla\cdot\mathbf{u}=0.
\]

End of test · preserve superscripts, subscripts, Greek letters, and delimiters.

Whitespace and harmless equivalent LaTeX grouping may differ. The automated
smoke test validates these prose/equation fragments in order, rejects truncation,
and rejects repeated/missing page boundaries.
