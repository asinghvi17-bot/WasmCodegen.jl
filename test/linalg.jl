# LinearAlgebra: BLAS and LAPACK implemented in the runtime (src/runtime/blas.jl, lapack.jl)

using LinearAlgebra

# a well-conditioned matrix (results within rounding of an optimized BLAS's)
wmat(m, n, s) = [1.0 / (a + b - 1) + (a == b ? 2.0 : 0.0) + 0.1 * sin(a * 3.7 + b * 1.3 + s) for a in 1:m, b in 1:n]
vec4(x) = (x[1], x[2], x[3], x[4])

la_dot(n::Int) = (v = [sin(k + 0.5n) for k in 1:10n]; w = [cos(1.5k) for k in 1:10n];
                  (dot(v, w), norm(v), norm(v, 1), Float64(LinearAlgebra.BLAS.iamax(v))))
la_gemm(n::Int) = (A = wmat(n + 3, 5, 0.1); B = wmat(5, 4, 0.7); C = A * B; D = A' * A; E = A * A';
                   (C[1, 1], C[end, end], D[2, 3], E[end, 1], sum(A * ones(5)), sum(A' * ones(n + 3))))
la_gemm32(n::Int) = (A = Float32.(wmat(n + 3, 5, 0.1)); B = Float32.(wmat(5, 4, 0.7)); C = A * B;
                     (Float64(C[1, 1]), Float64(C[end, end]), Float64(sum(A' * A))))
la_mul!(n::Int) = (A = wmat(5, 4, 0.3); B = wmat(4, 6, 0.2); C = ones(5, 6); mul!(C, A, B, 2.0, 0.5);
                   x = ones(5); mul!(x, A, ones(4), 1.0, 3.0); (C[1, 1], C[5, 6], x[1], x[5]))
la_tri(n::Int) = (A = wmat(5, 5, 0.1); b = [1.0 * k for k in 1:5]; B = wmat(5, 3, 0.4);
                  (sum(UpperTriangular(A) \ b), sum(LowerTriangular(A) \ B), sum(UpperTriangular(A)' \ b),
                   sum(UpperTriangular(A) * b), sum(B' / UpperTriangular(A)), sum(Symmetric(A) * b), sum(inv(UpperTriangular(A)))))
la_lu(n::Int) = (A = wmat(n + 3, n + 3, 0.3); b = [1.0 * k for k in 1:n+3]; F = lu(A);
                 (det(A), sum(A \ b), sum(inv(A)), sum(F.L), sum(F.U), Float64(sum(F.p)), logabsdet(A)[1]))
la_chol(n::Int) = (A = wmat(n + 3, n + 3, 0.2); A = A' * A; b = [1.0 * k for k in 1:n+3]; C = cholesky(A);
                   (sum(C.U), sum(C \ b), det(C), Float64(isposdef(A)), Float64(isposdef(-A))))
# a pivot that is not positive is reported, a NaN one is not (OpenBLAS's `potrf`)
la_chol_info(x::Float64, upper::Bool) = (C = cholesky(Symmetric([4.0 x 1.0; x 1.0 0.0; 1.0 0.0 5.0], upper ? :U : :L); check=false);
                                         d = C.factors[2, 2]; (Float64(C.info), Float64(isnan(d)), isnan(d) ? 0.0 : d, C.factors[1, 1]))
la_qr(n::Int) = (A = wmat(n + 4, 4, 0.3); b = [1.0 * k for k in 1:n+4]; F = qr(A);
                 (vec4(F \ b)..., abs(F.R[1, 1]), abs(F.R[4, 4]), sum(abs.(F.Q' * b))))
la_qrp(n::Int) = (A = wmat(n + 4, 4, 0.3); b = [1.0 * k for k in 1:n+4]; F = qr(A, ColumnNorm());
                  (vec4(F \ b)..., Float64(F.p[1]), abs(F.R[1, 1])))
la_lsq(n::Int) = (A = wmat(3, 5 + n, 0.2); x = A \ [1.0, 2.0, 3.0]; (x[1], x[2], x[end], sum(x)))
la_rankdef(n::Int) = (A = wmat(6, 3, 0.1); A = hcat(A, A[:, 1] + A[:, 2]); x = A \ [1.0 * k for k in 1:6]; vec4(x))

# eigenvectors and singular vectors are defined up to sign: compared by their absolute values
la_eigen(n::Int) = (A = wmat(n + 3, n + 3, 0.2); S = Symmetric(A + A'); E = eigen(S); w = eigvals(S);
                    (w[1], w[end], sum(w), sum(abs.(E.vectors)), abs(E.vectors[1, 1]), sum(eigvals(S, 1:2))))
la_svd(n::Int) = (A = wmat(n + 4, 3, 0.4); F = svd(A); s = svdvals(A);
                  (s[1], s[end], F.S[2], sum(abs.(F.U)), sum(abs.(F.Vt)), sum(abs.(svd(A'; full=true).U)),
                   Float64(rank(A)), opnorm(A), cond(A), sum(pinv(A))))
# symmetric indefinite (Bunch-Kaufman, its rook variant): a zero diagonal makes 2×2 pivots
function la_bk(n::Int, upper::Bool, rook::Bool)
    uplo = upper ? :U : :L
    A = wmat(n + 4, n + 4, 0.5); B = A + A'
    for k in 1:2:n+4
        B[k, k] = 0.0
    end
    S = Symmetric(B, uplo); b = [1.0 * k for k in 1:n+4]
    F = bunchkaufman(S, rook)
    return (sum(F \ b), det(F), sum(S \ b), sum(F \ [b 2b]))
end
# (the full Vt of a wide matrix: its first rows only, the rest a basis of its null space)
la_gesvd(n::Int) = (A = wmat(n + 4, 3, 0.4); F = svd(A; alg=LinearAlgebra.QRIteration());
                    G = svd(A'; full=true, alg=LinearAlgebra.QRIteration());
                    (F.S[1], F.S[end], sum(abs.(F.U)), sum(abs.(F.Vt)), sum(abs.(G.U)), sum(abs.(G.Vt[1:3, :]))))

# elements near the ends of the floating-point range: the reflectors and the column norms are
# scaled, as LAPACK's are
la_qr_scaled(s::Float64) = (A = s .* [1.0 2.0; 3.0 4.0; 5.0 7.0]; F = qr(A); R = F.R;
                            (R[1, 1] / s, R[1, 2] / s, R[2, 2] / s, sum(Matrix(F.Q))))
la_qrp_scaled(s::Float64) = (A = s .* [1.0 3.0 0.5; 1.0 4.0 0.1; 0.0 1.0 0.2]; F = qr(A, ColumnNorm());
                             (Float64(F.p[1]), Float64(F.p[2]), Float64(F.p[3]), abs(F.R[1, 1]) / s))
# increments: `nrm2` takes negative ones, `asum` and `iamax` do not (a zero one: differs
# between versions of OpenBLAS)
la_inc(n::Int) = (x = [1.0, 2.0, 3.0, 4.0, 5.0, -9.0];
                  (BLAS.nrm2(n, x, -2), BLAS.nrm2(n, x, 2), BLAS.nrm2(1, x, -1),
                   BLAS.asum(n, x, -2), Float64(BLAS.iamax(n, x, -2))))
# a long thin matrix (the workspace the routines ask for does not grow with its square)
la_svd_thin(m::Int) = (A = [sin(0.37i + j) for i in 1:m, j in 1:2]; s = svdvals(A);
                       F = svd(A; alg=LinearAlgebra.QRIteration()); (s[1], s[2], F.S[1], F.S[2], sum(abs.(F.Vt))))
# `gesdd` overwriting A with the singular vectors: U where it is tall, Vᵀ where it is wide
function la_gesdd_o(s::Float64, tall::Bool)
    A = tall ? [1.0 2.0; 3.0 4.0; 5.0 s] : [1.0 3.0 5.0; 2.0 4.0 s]
    U, S, VT = LinearAlgebra.LAPACK.gesdd!('O', A)
    (S[1], S[2], sum(abs.(U)), sum(abs.(VT)), abs(U[1, 1]), abs(VT[2, 2]),
     Float64(10size(U, 1) + size(U, 2)), Float64(10size(VT, 1) + size(VT, 2)))
end

# elements that are not finite: NaN singular values, but `gesdd` rejects a NaN (its argument 4)
function la_svd_nonfinite(x::Float64)
    A = [x 1.0; 1.0 2.0]
    dd = try
        Float64(all(isnan, LinearAlgebra.LAPACK.gesdd!('N', copy(A))[2]))
    catch e
        e isa ArgumentError ? -4.0 : -1.0
    end
    return (dd, Float64(all(isnan, LinearAlgebra.LAPACK.gesvd!('N', 'N', copy(A))[2])),
            Float64(all(isnan, LinearAlgebra.LAPACK.gesvd!('S', 'S', copy(A))[2])))
end

# strides: increments other than 1 (negative: from the far end), and views with a row stride
la_strides(n::Int) = (x = [1.0 * k for k in 1:2n+1]; y = [0.5 * k * k for k in 1:3n+1];
                      d = BLAS.dot(n, x, 2, y, 3); e = BLAS.dot(n, x, -2, y, 3);
                      BLAS.axpy!(n, 2.0, x, 2, y, -3); BLAS.scal!(n, 3.0, x, 2);
                      z = zeros(2n); BLAS.blascopy!(n, x, -2, z, 2);
                      (d, e, sum(y), y[1], sum(x), x[3], z[1], sum(z)))
la_strided_views(n::Int) = (A = wmat(6, 5, 0.3); V = view(A, 1:2:5, 2:4); x = view([1.0 * k for k in 1:9], 1:3:7);
                            y = V * x; W = view(A, 2:4, 1:3) * view(A, 1:3, 2:5);
                            (y[1], y[3], sum(V' * y), W[1, 1], W[3, 4], dot(x, view(A, 1, 1:3)), norm(view(A, 2, :))))
# elements near the ends of the floating-point range: the matrix is scaled before the rotations
la_eig_scaled(s::Float64) = (A = wmat(4, 4, 0.2); E = eigen(Symmetric(s .* (A + A')));
                             (E.values[1] / s, E.values[end] / s, sum(abs.(E.vectors)), abs(E.vectors[2, 3])))
la_svd_scaled(s::Float64) = (A = s .* wmat(5, 3, 0.4); F = svd(A);
                             (F.S[1] / s, F.S[end] / s, sum(abs.(F.U)), sum(abs.(F.Vt)), svdvals(A')[2] / s))
# `info`: the first zero pivot of `lu`, the zero on the diagonal of a triangular solve, the
# zero pivot of `bunchkaufman`; and an exactly singular matrix's errors
function la_info(k::Int)
    A = [1.0 2.0 3.0; 2.0 4.0 6.0; 1.0 0.0 1.0]
    k == 0 && return (Float64(lu(A; check=false).info), Float64(issuccess(lu(A; check=false))), 0.0)
    k == 1 && return (Float64(bunchkaufman(Symmetric(zeros(3, 3)); check=false).info),
                      Float64(cholesky(Symmetric(-A * A'); check=false).info), 0.0)
    T = [1.0 2.0 3.0; 0.0 0.0 1.0; 0.0 0.0 2.0]
    r = try
        k == 2 ? sum(LinearAlgebra.LAPACK.trtrs!('U', 'N', 'N', T, [1.0, 2.0, 3.0])) : sum(A \ [1.0, 2.0, 3.0])
    catch e
        e isa SingularException ? -Float64(e.info) : e isa LinearAlgebra.LAPACKException ? -10.0 - e.info : -100.0
    end
    return (r, 0.0, 0.0)
end
# a tall matrix: the thin and the full factors
# columns whose norms' squares underflow, or whose ratio's overflows
la_svd_tiny(x::Float64) = (s = svdvals([1.0 x; 0.0 0.0]); d = svdvals([1.0 0.0; 0.0 x]);
                           F = svd([1.0 0.0; 0.0 x]); (s[1], s[2], d[1], d[2] / x, F.S[2] / x, sum(abs.(F.U))))
la_svd_tiny32(x::Float32) = (s = svdvals(Float32[1 x; 0 0]); d = svdvals(Float32[1 0; 0 x]); (s[1], s[2], d[1], d[2] / x))
# a column small beside another and not orthogonal to it; the last vector of a full basis
# far from every unit vector
la_svd_skew(x::Float64) = (F = svd([1.0 x; 0.0 x]); (F.S[1], F.S[2] / x, sum(abs2, F.U' * F.U - I), sum(abs2, F.Vt * F.Vt' - I)))
la_svd_full(n::Int) = (A = [Matrix{Float64}(I, n, n); -ones(1, n)]; F = svd(A; full=true);
                       (sum(abs2, F.U[:, end]), sum(abs2, F.U' * F.U - I), F.S[1], F.S[end]))
# of rank 1; a column of subnormal elements; norms whose ratio underflows; elements that a
# scaling of the largest to 1 would lose
la_svd_orth(F) = (sum(abs2, F.U' * F.U - I), sum(abs2, F.Vt * F.Vt' - I))
la_svd_rank1(a::Float64, b::Float64) = (F = svd([a b; 4a 4b]; full=true); (F.S[1], la_svd_orth(F)...))
la_svd_subnormal() = (d = nextfloat(0.0); F = svd([1.0 0.0; 0.0 d; 0.0 d]; full=true); (F.S[1], la_svd_orth(F)...))
la_svd_ratio(x::Float64, y::Float64) = (F = svd([x y; 0.0 y]); (F.S[1] / x, F.S[2] / y, la_svd_orth(F)...))
la_svd_range(x::Float64, y::Float64) = (F = svd([x 0.0; 0.0 y]); (F.S[1] / x, F.S[2] / y, la_svd_orth(F)...))
# a small column whose part orthogonal to the large one is smaller yet; a subnormal column
# that is not orthogonal to the other; many more rows than columns
la_svd_small() = (e = eps(); F = svd([1.0 e; 0.0 e^2 / 2]); (F.S[1], F.S[2] / e^2, la_svd_orth(F)...))
la_svd_near(y::Float64) = (F = svd([1.0 y; 1.0 2y]); (F.S[1], F.S[2] / y, la_svd_orth(F)...))
la_svd_mixed(y::Float32) = (A = Float32[3 -4 -5; 4 -5 0; 1 -2 -4]; A[:, 2:3] .*= y; F = svd(A);
                            (isapprox(F.S[1], 5.0990195f0; rtol=1f-5), all(<(1f-5), la_svd_orth(F))))
la_svd_stuck() = (F = svd([1.0 nextfloat(0.0); 1.0 0.0]); (F.S[1], la_svd_orth(F)...))
la_svd_long(n::Int) = (A = zeros(Float32, n, 2); A[1, 1] = 1; A[1, 2] = 0.1f0; A[2, 2] = 1; F = svd(A);
                       (round(Float64(F.S[1]); digits=4), round(Float64(F.S[2]); digits=4)))
# (columns that are orthogonal: the rounding of their product's many terms is no rotation left)
la_svd_rows(n::Int) = (F = svd(repeat(Float64[2 5; 1 4; 2 -7], inner=(n, 1))); (F.S[1], F.S[2]))
# (a long column of elements small beside one: their squares are not rounded away)
la_svd_tail(n::Int) = (A = reshape(vcat(zeros(Float32, 1023), 1f0, fill(2f0^-12, n)), :, 1); F = svd(A);
                       (round(Float64(F.S[1]); digits=5), round(Float64(sum(abs2, F.U)); digits=4)))
la_svd_tall(n::Int) = (A = wmat(n + 6, 2, 0.3); F = svd(A); G = svd(A; full=true);
                       (F.S[1], F.S[2], Float64(size(F.U, 2)), Float64(size(G.U, 2)), sum(abs.(F.U)),
                        sum(abs.(G.U[:, 1:2])), sum(abs.(G.U' * G.U)), sum(abs.(G.Vt)), sum(abs.(F.U * Diagonal(F.S) * F.Vt - A))))
# `gesvd` overwriting A with the left or the right singular vectors (its first min(m, n)
# columns or rows: the rest of A is not defined)
function la_gesvd_o(s::Float64, tall::Bool, left::Bool)
    A = tall ? [1.0 2.0; 3.0 4.0; 5.0 s] : [1.0 3.0 5.0; 2.0 4.0 s]
    U, S, VT = left ? LinearAlgebra.LAPACK.gesvd!('O', 'S', A) : LinearAlgebra.LAPACK.gesvd!('A', 'O', A)
    (S[1], S[2], sum(abs.(U[:, 1:2])), sum(abs.(VT[1:2, :])), abs(U[1, 1]), abs(VT[2, 2]),
     Float64(10size(U, 1) + size(U, 2)), Float64(10size(VT, 1) + size(VT, 2)))
end
# job characters LAPACK does not have, or not together (LinearAlgebra rejects them): 1 for an
# ArgumentError
const SVD_JOBS = ('A', 'S', 'O', 'N', 'X', 's')
function la_svd_jobs(i::Int, j::Int)
    A = [1.0 2.0; 3.0 4.0; 5.0 6.0]
    dd = try; LinearAlgebra.LAPACK.gesdd!(SVD_JOBS[i], copy(A))[2][1]; catch e; e isa ArgumentError ? 1.0 : 2.0; end
    vd = try; LinearAlgebra.LAPACK.gesvd!(SVD_JOBS[i], SVD_JOBS[j], copy(A))[2][1]; catch e; e isa ArgumentError ? 1.0 : 2.0; end
    return (dd, vd)
end

@testset "Jacobi iterations that do not converge" begin
    L = WasmCodegen.Runtime.LAPACK
    A = wmat(5, 4, 0.2); S = A' * A
    @test L.jacobi_eigen!(copy(S), 4)[3]
    @test !L.jacobi_eigen!(copy(S), 4, 1)[3]
    @test L.jacobi_svd(5, 4, copy(A).ref, 5, false, false)[4]
    @test !L.jacobi_svd(5, 4, copy(A).ref, 5, false, false, 1)[4]
    @test L.jacobi_svd(4, 5, copy(A')[:, :].ref, 4, true, true)[4]
    # job characters, in either case (the runtime's `gesdd!` and `gesvd!` set a negative `info`
    # for others, which LinearAlgebra does not pass them)
    @test map(c -> L.svd_job(UInt8(c)), ('N', 's', 'O', 'a', 'X', 'V')) ==
          (L.JOB_NONE, L.JOB_THIN, L.JOB_OVER, L.JOB_ALL, L.JOB_INVALID, L.JOB_INVALID)
end

@testset "linear algebra" begin
    for x in (NaN, Inf, -Inf, 1.0)
        @wtest la_svd_nonfinite(x)
    end
    for s in (1e-310, 1e-300, 1.0, 1e200, 1e300)
        @wtest_approx la_qr_scaled(s)
        @wtest_approx la_qrp_scaled(s)
    end
    @wtest_approx la_inc(3)
    for n in 1:3
        @wtest_approx la_strides(n)
    end
    @wtest_approx la_strided_views(1)
    for s in (1e-300, 1.0, 1e200)
        @wtest_approx la_eig_scaled(s)
        @wtest_approx la_svd_scaled(s)
    end
    for k in 0:3
        @wtest_approx la_info(k)
    end
    @wtest_approx la_svd_tall(1)
    for x in (1e-320, 1e-200, 1e-3)
        @wtest_approx la_svd_tiny(x)
    end
    for x in (5e-309, 1e-200, 1e-9, 0.5)
        @wtest_approx la_svd_skew(x)
    end
    @wtest_approx la_svd_full(100)
    @wtest_approx la_svd_rank1(1.0, 4.0)
    @wtest_approx la_svd_rank1(3.0, 4.0)
    @wtest_approx la_svd_subnormal()
    @wtest_approx la_svd_ratio(1e100, 1e-300)
    @wtest_approx la_svd_range(1e200, 1e-200)
    @wtest_approx la_svd_small()
    @wtest_approx la_svd_near(1e-300)
    @wtest_approx la_svd_near(1e-308)
    @wtest_approx la_svd_stuck()
    @wtest_approx la_svd_long(1_000_000)
    @wtest la_svd_mixed(1f-38)
    @wtest_approx la_svd_rows(100)
    @wtest_approx la_svd_tail(64512)
    for x in (1f-40, 1f-30)
        @wtest_approx la_svd_tiny32(x)
    end
    for x in (1.0, 3.0, NaN, Inf, -Inf), upper in (true, false)
        @wtest_approx la_chol_info(x, upper)
    end
    @wtest_approx la_svd_thin(20000)
    @wtest_approx la_gesdd_o(6.0, true)
    @wtest_approx la_gesdd_o(6.0, false)
    for tall in (true, false), left in (true, false)
        @wtest_approx la_gesvd_o(6.0, tall, left)
    end
    for (i, j) in ((1, 2), (3, 3), (5, 4), (4, 5), (6, 4), (3, 4), (4, 3))
        @wtest_approx la_svd_jobs(i, j)
    end
    for n in 0:3, upper in (true, false), rook in (false, true)
        @wtest_approx la_bk(n, upper, rook)
    end
    for n in 1:2
        @wtest_approx la_gesvd(n)
    end
    for n in 1:3
        @wtest_approx la_eigen(n)
        @wtest_approx la_svd(n)
    end
    for n in 1:3
        @wtest_approx la_dot(n)
        @wtest_approx la_gemm(n)
        @wtest_approx la_lu(n)
        @wtest_approx la_chol(n)
        @wtest_approx la_qr(n - 1)
        @wtest_approx la_qrp(n - 1)
        @wtest_approx la_lsq(n - 1)
    end
    @wtest la_gemm32(1)
    @wtest_approx la_mul!(1)
    @wtest_approx la_tri(1)
    @wtest_approx la_rankdef(1)
end
