! Cross-language benchmark: Fortran — binary search vs FAST FFI.
!
! Fortran's standard library does not include ordered tree containers.
! Manual binary search on a sorted array is the standard approach.
! No widely-used tree library exists for Fortran.
!
! Compile:
!   gfortran -O3 -o bench_fortran ../../bindings/fortran/fast_binding.f90 \
!       bench_fortran.f90 -L../../build -lfast -Wl,-rpath,../../build

program bench_fortran
  use, intrinsic :: iso_c_binding
  use fast_binding
  implicit none

  integer(c_int32_t), allocatable :: keys(:), queries(:)
  integer(c_size_t) :: tree_size, num_queries, warmup
  type(c_ptr) :: tree
  integer(c_int64_t) :: sink
  integer :: i, argc
  character(len=32) :: arg
  real(c_double) :: t0, t1
  integer(c_int32_t) :: max_key

  ! Parse arguments
  tree_size = 1000000
  num_queries = 5000000
  argc = command_argument_count()
  if (argc >= 1) then
    call get_command_argument(1, arg)
    read(arg, *) tree_size
  end if
  if (argc >= 2) then
    call get_command_argument(2, arg)
    read(arg, *) num_queries
  end if

  ! Generate sorted keys
  allocate(keys(tree_size))
  do i = 1, int(tree_size)
    keys(i) = int((i - 1) * 3 + 1, c_int32_t)
  end do
  max_key = keys(tree_size)

  ! Generate random queries
  allocate(queries(num_queries))
  call srand(42)
  do i = 1, int(num_queries)
    queries(i) = int(mod(irand(), int(max_key + 1)), c_int32_t)
  end do

  warmup = min(num_queries, 100000_c_size_t)
  sink = 0

  ! --- FAST FFI ---
  tree = fast_create(keys, tree_size)

  do i = 1, int(warmup)
    sink = sink + fast_search(tree, queries(i))
  end do

  call cpu_time(t0)
  do i = 1, int(num_queries)
    sink = sink + fast_search(tree, queries(i))
  end do
  call cpu_time(t1)
  call emit_json("gfortran", "fast_ffi", tree_size, num_queries, t1 - t0)

  call fast_destroy(tree)

  ! --- Binary search ---
  do i = 1, int(warmup)
    sink = sink + binary_search(keys, tree_size, queries(i))
  end do

  call cpu_time(t0)
  do i = 1, int(num_queries)
    sink = sink + binary_search(keys, tree_size, queries(i))
  end do
  call cpu_time(t1)
  call emit_json("gfortran", "binary_search", tree_size, num_queries, t1 - t0)

  deallocate(keys)
  deallocate(queries)

  ! Prevent optimization
  if (sink == -huge(sink)) write(0, *) sink

contains

  function binary_search(arr, n, key) result(idx)
    integer(c_int32_t), intent(in) :: arr(:)
    integer(c_size_t), intent(in) :: n
    integer(c_int32_t), intent(in) :: key
    integer(c_int64_t) :: idx
    integer(c_size_t) :: lo, hi, mid

    if (key < arr(1)) then
      idx = -1
      return
    end if
    lo = 1
    hi = n
    do while (lo < hi)
      mid = lo + (hi - lo + 1) / 2
      if (arr(mid) <= key) then
        lo = mid
      else
        hi = mid - 1
      end if
    end do
    idx = int(lo - 1, c_int64_t)  ! 0-based
  end function

  subroutine emit_json(compiler, method, ts, nq, sec)
    character(len=*), intent(in) :: compiler, method
    integer(c_size_t), intent(in) :: ts, nq
    real(c_double), intent(in) :: sec
    real(c_double) :: mqs, nsq

    mqs = dble(nq) / sec / 1.0d6
    nsq = sec * 1.0d9 / dble(nq)
    write(*, '(A,A,A,A,A,I0,A,I0,A,F0.4,A,F0.2,A,F0.1,A)') &
      '{"language":"fortran","compiler":"', compiler, '","method":"', method, &
      '","tree_size":', ts, ',"num_queries":', nq, &
      ',"total_sec":', sec, ',"mqs":', mqs, ',"ns_per_query":', nsq, '}'
    flush(6)
  end subroutine

end program bench_fortran
