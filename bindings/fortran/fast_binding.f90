! Fortran bindings for the FAST search tree library.
!
! Usage:
!   use fast_binding
!   type(c_ptr) :: tree
!   integer(c_int32_t) :: keys(5) = [1, 3, 5, 7, 9]
!   tree = fast_create(keys, 5_c_size_t)
!   idx = fast_search(tree, 5_c_int32_t)
!   call fast_destroy(tree)

module fast_binding
  use, intrinsic :: iso_c_binding
  implicit none

  interface

    function fast_create(keys, n) result(tree) bind(C, name="fast_create")
      import :: c_ptr, c_int32_t, c_size_t
      integer(c_int32_t), intent(in) :: keys(*)
      integer(c_size_t), value, intent(in) :: n
      type(c_ptr) :: tree
    end function

    subroutine fast_destroy(tree) bind(C, name="fast_destroy")
      import :: c_ptr
      type(c_ptr), value, intent(in) :: tree
    end subroutine

    function fast_search(tree, key) result(idx) bind(C, name="fast_search")
      import :: c_ptr, c_int32_t, c_int64_t
      type(c_ptr), value, intent(in) :: tree
      integer(c_int32_t), value, intent(in) :: key
      integer(c_int64_t) :: idx
    end function

    function fast_search_lower_bound(tree, key) result(idx) &
        bind(C, name="fast_search_lower_bound")
      import :: c_ptr, c_int32_t, c_int64_t
      type(c_ptr), value, intent(in) :: tree
      integer(c_int32_t), value, intent(in) :: key
      integer(c_int64_t) :: idx
    end function

    function fast_size(tree) result(n) bind(C, name="fast_size")
      import :: c_ptr, c_size_t
      type(c_ptr), value, intent(in) :: tree
      integer(c_size_t) :: n
    end function

    function fast_key_at(tree, idx) result(key) bind(C, name="fast_key_at")
      import :: c_ptr, c_size_t, c_int32_t
      type(c_ptr), value, intent(in) :: tree
      integer(c_size_t), value, intent(in) :: idx
      integer(c_int32_t) :: key
    end function

  end interface

end module fast_binding
