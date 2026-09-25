#!/usr/bin/env python3
"""Deterministic semantic checks for the bundled DeepSeek OCR math fixture."""

from __future__ import annotations

import argparse
from pathlib import Path


CHECKS = {
    "heading": "OCRsmalltest",
    "Hello world": "Hello,world!",
    "English prose": "Thequickbrownfoxjumpsover13lazydogs.Mathmustbetranscribed,notsolved.",
    "Chinese prose": "中文测试：本地模型应该准确识别汉字、标点符号",
    "Euler identity": r"e^{i\pi}+1=0",
    "binomial theorem": r"(x+y)^{n}=\sum_{k=0}^{n}\binom{n}{k}x^{n-k}y^{k}",
    "vector norm": r"\|x\|_{2}=\sqrt{x_{1}^{2}+\cdots+x_{d}^{2}}",
    "Gaussian integral": r"\int_{-\infty}^{\infty}e^{-x^{2}}dx=\sqrt{\pi}",
    "zeta series": r"\zeta(s)=\sum_{n=1}^{\infty}\frac{1}{n^{s}}",
    "zeta domain": r"\Re(s)>1",
    "matrix environment": r"\begin{pmatrix}",
    "matrix alpha": r"\alpha",
    "matrix beta": r"\beta^{2}",
    "matrix fraction": r"\frac{1}{2}",
    "matrix square root": r"\sqrt{2}",
    "matrix complex entry": r"e^{i\theta}",
    "matrix determinant": r"\det(\mathbf{A}-\lambda\mathbf{I})=0",
    "piecewise function": r"\begin{cases}x^{2}\sin(1/x),&x\neq0",
    "piecewise zero branch": r"0,&x=0",
    "Maxwell Gauss law": r"\nabla\cdot\mathbf{E}=\frac{\rho}{\varepsilon_{0}}",
    "Maxwell magnetic law": r"\nabla\cdot\mathbf{B}=0",
    "Maxwell Faraday law": r"\nabla\times\mathbf{E}=-\frac{\partial\mathbf{B}}{\partialt}",
    "Maxwell Ampere law": r"\nabla\times\mathbf{B}=\mu_{0}\mathbf{J}+\mu_{0}\varepsilon_{0}\frac{\partial\mathbf{E}}{\partialt}",
    "Navier-Stokes": r"\frac{\partial\mathbf{u}}{\partialt}+(\mathbf{u}\cdot\nabla)\mathbf{u}",
    "Navier-Stokes pressure": r"=-\frac{1}{\rho}\nabla p".replace(" ", ""),
    "Navier-Stokes viscosity": r"+\nu\nabla^{2}\mathbf{u}+\mathbf{f}",
    "incompressibility": r"\nabla\cdot\mathbf{u}=0",
    "end marker": "Endoftest·preservesuperscripts,subscripts,Greekletters,anddelimiters.",
}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path, help="bridge-smoke output or device report")
    args = parser.parse_args()

    compact = "".join(args.output.read_text(encoding="utf-8").split()).replace("&=", "=")
    missing = []
    cursor = 0
    for name, fragment in CHECKS.items():
        position = compact.find(fragment, cursor)
        if position < 0:
            missing.append(name)
        else:
            cursor = position + len(fragment)
    if len(compact) > 8_000:
        missing.append("bounded output length")
    if "OCR:OCR:OCR:" in compact:
        missing.append("no startup repetition loop")
    for name, marker in (("single heading", "OCRsmalltest"), ("single end marker", "Endoftest")):
        if compact.count(marker) != 1:
            missing.append(name)
    if missing:
        print("Math OCR verification failed: " + ", ".join(missing))
        return 1
    print(f"Math OCR verification passed ({len(CHECKS)}/{len(CHECKS)} checks).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
