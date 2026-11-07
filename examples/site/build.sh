#!/usr/bin/env bash
# The examples' pages, as GitHub Pages serves them:
#   build.sh <example> <dir>   builds the example's page as its README does, running its check,
#                              into <dir>/<example>.html
#   build.sh index <dir>       the index, into <dir>/index.html
# JULIA and NODE name the commands (as JULIA="julia +1.13").
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$2"
out=$(cd "$2" && pwd)
julia=(${JULIA:-julia} --project=.)
node=(${NODE:-node} --experimental-wasm-exnref)

# (the pages are written as a document's body: head.html begins the document)
page() { cat "$here/head.html" "$1" > "$out/$2"; }

if [ "$1" = index ]; then
    commit=${GITHUB_SHA:-$(git -C "$here" rev-parse HEAD)}
    sed "s/__COMMIT__/$commit/g; s/__SHORT__/${commit:0:7}/g" "$here/index.html" > "$out/index.body"
    page "$out/index.body" index.html
    rm "$out/index.body"
    exit
fi

cd "$here/../$1"
"${julia[@]}" -e 'using Pkg; Pkg.instantiate()'
case $1 in
    brusselator)
        "${julia[@]}" native.jl
        "${julia[@]}" build.jl
        "${node[@]}" check.mjs
        "${julia[@]}" page.jl
        page brusselator.html brusselator.html ;;
    images)
        "${julia[@]}" build.jl
        "${julia[@]}" native.jl
        "${node[@]}" check.mjs
        "${julia[@]}" page.jl
        page images.html images.html ;;
    juliasyntax)
        "${julia[@]}" build.jl
        "${julia[@]}" reference.jl
        "${node[@]}" check.mjs
        "${julia[@]}" page.jl
        page parser.html juliasyntax.html ;;
    lorenz)
        "${julia[@]}" build.jl
        "${node[@]}" run.mjs lorenz.wasm
        "${julia[@]}" page.jl
        page lorenz.html lorenz.html ;;
    mtk)
        "${julia[@]}" build.jl
        "${node[@]}" check.mjs
        "${julia[@]}" page.jl
        page oscillator.html mtk.html ;;
    *)
        echo "build.sh: no example $1" >&2
        exit 1 ;;
esac
