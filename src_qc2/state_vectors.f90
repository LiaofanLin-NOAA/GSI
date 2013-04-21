module state_vectors
!$$$  module documentation block
!            .      .    .                                       .
! module:    state_vectors
!  prgmmr: tremolet
!
! abstract: define state vectors and basic operators
!
! program history log:
!   2007-04-13  tremolet - initial code
!   2007-05-10  todling  - expanded interface to dot_product
!   2008-01-04  tremolet - improve allocate/deallocate
!   2008-04-28  guo      - add norms1 for more detailed info
!   2008-11-27  todling  - add tsen and p3d for Map-2008 update
!   2009-01-27  todling  - rename prt_norms to prevent IBM compiler confusion
!   2009-08-12  lueken   - update documentation
!   2010-05-13  todling  - udpate to use gsi_bundle (now the state_vector)
!                        - declare all private (explicit public)
!                        - remove following:  assignment, sum(s)
!   2011-05-20  guo      - add a rank-1 interface of dot_product()
!   2011-07-04  todling  - fixes to run either single or double precision
!
! subroutines included:
!   sub setup_state_vectors
!   sub allocate_state
!   sub deallocate_state
!   sub norms_vars
!   sub prt_norms1
!   sub prt_norms0
!   sub set_random_st
!   sub inquire_state
!   sub init_anasv
!
! functions included:
!   dot_prod_st
!
! attributes:
!   language: f90
!   machine:
!
!$$$

use kinds, only: r_kind,i_kind,r_single,r_double,r_quad
use constants, only: one,zero,zero_quad,max_varname_length
use mpimod, only: mype
use file_utility, only : get_lun
use mpl_allreducemod, only: mpl_allreduce
use GSI_BundleMod, only : GSI_BundleCreate
use GSI_BundleMod, only : GSI_Bundle
use GSI_BundleMod, only : GSI_BundleGetPointer
use GSI_BundleMod, only : GSI_BundlePrint
use GSI_BundleMod, only : dplevs => GSI_BundleDplevs
use GSI_BundleMod, only : sum_mask => GSI_BundleSum
use GSI_BundleMod, only : GSI_BundleDestroy
use GSI_BundleMod, only : GSI_BundleUnset

use GSI_BundleMod, only : GSI_Grid
use GSI_BundleMod, only : GSI_GridCreate

use mpeu_util, only: gettablesize
use mpeu_util, only: gettable

implicit none

save
private 
  public  allocate_state
  public  deallocate_state
  public  prt_state_norms
  public  setup_state_vectors
  public  dot_product
  public  set_random 
  public  inquire_state
  public  init_anasv
  public  final_anasv
  public  svars2d
  public  svars3d
  public  svars
  public  edges
  public  ns2d,ns3d

! State vector definition
! Could contain model state fields plus other fields required
! by observation operators that can be saved from TL model run
! (from the physics or others)

character(len=*),parameter::myname='state_vectors'
integer(i_kind) :: nval_len,latlon11,latlon1n,latlon1n1,lat2,lon2,nsig

logical :: llinit = .false.
integer(i_kind) :: m_st_alloc, max_st_alloc, m_allocs, m_deallocs

integer(i_kind) :: nvars,ns2d,ns3d
character(len=max_varname_length),allocatable,dimension(:) :: svars
character(len=max_varname_length),allocatable,dimension(:) :: svars3d
character(len=max_varname_length),allocatable,dimension(:) :: svars2d
logical,allocatable,dimension(:)          :: edges


! ----------------------------------------------------------------------
INTERFACE PRT_STATE_NORMS
  MODULE PROCEDURE prt_norms0,prt_norms1
END INTERFACE

INTERFACE DOT_PRODUCT
MODULE PROCEDURE dot_prod_st
MODULE PROCEDURE dot_prod_st_r1
END INTERFACE

INTERFACE SET_RANDOM
MODULE PROCEDURE set_random_st
END INTERFACE

! ----------------------------------------------------------------------
contains
! ----------------------------------------------------------------------
subroutine setup_state_vectors(katlon11,katlon1n,kval_len,kat2,kon2,ksig)
!$$$  subprogram documentation block
!                .      .    .                                       .
! subprogram:    setup_state_vectors
!   prgmmr: tremolet
!
! abstract:
!
! program history log:
!   2009-08-12  lueken - added subprogram doc block
!
!   input argument list:
!     katlon11,katlon1n,kval_len,kat2,kon2,ksig
!
!   output argument list:
!
! attributes:
!   language: f90
!   machine:
!
!$$$ end documentation block

  implicit none
  integer(i_kind), intent(in   ) :: katlon11,katlon1n,kval_len,kat2,kon2,ksig
  integer(i_kind) i,ii

  latlon11=katlon11
  latlon1n=katlon1n
  nval_len=kval_len
  lat2=kat2
  lon2=kon2
  nsig=ksig
  latlon1n1=latlon1n+latlon11

  llinit = .true.

  m_st_alloc=0
  max_st_alloc=0
  m_allocs=0
  m_deallocs=0

  return
end subroutine setup_state_vectors
! ----------------------------------------------------------------------
subroutine init_anasv
implicit none
!character(len=*),parameter:: rcname='anavinfo.txt'
character(len=*),parameter:: rcname='anavinfo'  ! filename should have extension
character(len=*),parameter:: tbname='state_vector::'
integer(i_kind) luin,i,ii,ntot
character(len=256),allocatable,dimension(:):: utable
character(len=20) var,amedge,source,funcof
character(len=*),parameter::myname_=myname//'*init_anasv'
integer(i_kind) ilev, itracer

! load file
luin=get_lun()
open(luin,file=rcname,form='formatted')

! Scan file for desired table first
! and get size of table
call gettablesize(tbname,luin,ntot,nvars)

! Get contents of table
allocate(utable(nvars))
call gettable(tbname,luin,ntot,nvars,utable)

! release file unit
close(luin)

! Retrieve each token of interest from table and define
! variables participating in state vector

! Count variables first
ns3d=0; ns2d=0
do ii=1,nvars
   read(utable(ii),*) var, ilev, itracer, amedge, source, funcof
   if(ilev>1) then
       ns3d=ns3d+1
   else if(ilev==1) then
       ns2d=ns2d+1
   else
       write(6,*) myname_,': error, unknown number of levels'
       call stop2(999)
   endif
enddo

allocate(svars3d(ns3d),svars2d(ns2d),edges(ns3d))

! Now load information from table
ns3d=0;ns2d=0
edges=.false.
do ii=1,nvars
   read(utable(ii),*) var, ilev, itracer, amedge, source, funcof
   if(ilev>1) then
      ns3d=ns3d+1
      svars3d(ns3d)=trim(adjustl(var))
      if(trim(amedge)=='yes') edges(ns3d)=.true. 
   else
      ns2d=ns2d+1
      svars2d(ns2d)=trim(adjustl(var))
   endif
enddo

deallocate(utable)

allocate(svars(nvars))

! Fill in array w/ all var names (must be 3d first, then 2d)
ii=0
do i=1,ns3d
   ii=ii+1
   svars(ii)=svars3d(i)
enddo
do i=1,ns2d
   ii=ii+1
   svars(ii)=svars2d(i)
enddo

if (mype==0) then
    write(6,*) myname_,':  2D-STATE VARIABLES ', svars2d
    write(6,*) myname_,':  3D-STATE VARIABLES ', svars3d
    write(6,*) myname_,': ALL STATE VARIABLES ', svars
end if

end subroutine init_anasv
subroutine final_anasv
implicit none
deallocate(svars)
deallocate(svars3d,svars2d,edges)
end subroutine final_anasv
! ----------------------------------------------------------------------
subroutine allocate_state(yst)
!$$$  subprogram documentation block
!                .      .    .                                       .
! subprogram:    allocate_state
!   prgmmr: tremolet
!
! abstract:
!
! program history log:
!   2009-08-12  lueken - added subprogram doc block
!   2010-05-13  todling - major revamp: state now a gsi_bundle
!
!   input argument list:
!
!   output argument list:
!    yst  - state vector
!
! attributes:
!   language: f90
!   machine:
!
!$$$ end documentation block
  implicit none
  type(gsi_bundle), intent(inout) :: yst
  type(gsi_grid) :: grid
  integer(i_kind) :: ierror
  character(len=80) :: bname

  call GSI_GridCreate(grid,lat2,lon2,nsig)
  write(bname,'(a)') 'State Vector'
  call GSI_BundleCreate(yst,grid,bname,ierror, &
                        names2d=svars2d,names3d=svars3d,edges=edges,bundle_kind=r_kind)  

  if (yst%ndim/=nval_len) then
     write(6,*)'allocate_state: error length'
     call stop2(313)
  end if

  m_st_alloc=m_st_alloc+1
  if (m_st_alloc>max_st_alloc) max_st_alloc=m_st_alloc
  m_allocs=m_allocs+1

  return
end subroutine allocate_state
! ----------------------------------------------------------------------
subroutine deallocate_state(yst)
!$$$  subprogram documentation block
!                .      .    .                                       .
! subprogram:    deallocate_state
!   prgmmr: tremolet
!
! abstract:
!
! program history log:
!   2009-08-12  lueken - added subprogram doc block
!   2010-05-13  todling - major revamp: state now a gsi_bundle
!
!   input argument list:
!    yst
!
!   output argument list:
!    yst
!
! attributes:
!   language: f90
!   machine:
!
!$$$ end documentation block
  implicit none
  type(gsi_bundle), intent(inout) :: yst
  integer(i_kind) ierror

  call GSI_BundleDestroy(yst,ierror)
  if(ierror/=0) then
     write(6,*)'deallocate_state warning: vector not allocated'
  endif

  m_st_alloc=m_st_alloc-1
  m_deallocs=m_deallocs+1

  return
end subroutine deallocate_state
! ----------------------------------------------------------------------
subroutine norms_vars(xst,pmin,pmax,psum,pnum)
!$$$  subprogram documentation block
!                .      .    .                                       .
! subprogram:    norms_vars
!   prgmmr:
!
! abstract:
!
! program history log:
!   2009-08-12  lueken - added subprogram doc block
!   2010-05-15  todling - update to use gsi_bundle
!   2010-06-02  todling - generalize to be order-independent
!   2010-06-10  treadon - correct indexing for psum,pnum arrays
!
!   input argument list:
!    xst
!
!   output argument list:
!    pmin,pmax,psum,pnum
!
! attributes:
!   language: f90
!   machine:
!
!$$$ end documentation block 
  use mpimod, only: ierror,mpi_comm_world,mpi_rtype,npe
  implicit none
  type(gsi_bundle), intent(in   ) :: xst
  real(r_kind)    , intent(  out) :: pmin(nvars),pmax(nvars),psum(nvars),pnum(nvars)

! local variables
  real(r_kind) :: zloc(3*nvars+3),zall(3*nvars+3,npe),zz
  integer(i_kind) :: i,ii

  zloc=zero
  pmin=zero
  pmax=zero
  psum=zero
  pnum=one

! Independent part of vector
! Sum
  ii=0
  do i = 1,ns3d
     ii=ii+1
     if(xst%r3(i)%mykind==r_single)then
        zloc(ii)= sum_mask(xst%r3(i)%qr4,ihalo=1)
     else
        zloc(ii)= sum_mask(xst%r3(i)%q,ihalo=1)
     endif
  enddo
  do i = 1,ns2d
     ii=ii+1
     if(xst%r2(i)%mykind==r_single)then
        zloc(ii)= sum_mask(xst%r2(i)%qr4,ihalo=1)
     else
        zloc(ii)= sum_mask(xst%r2(i)%q,ihalo=1)
     endif
  enddo
! Min
  do i = 1,ns3d
     ii=ii+1
     if(xst%r3(i)%mykind==r_single)then
        zloc(ii)= minval(xst%r3(i)%qr4)
     else
        zloc(ii)= minval(xst%r3(i)%q)
     endif
  enddo
  do i = 1,ns2d
     ii=ii+1
     if(xst%r2(i)%mykind==r_single)then
        zloc(ii)= minval(xst%r2(i)%qr4)
      else
        zloc(ii)= minval(xst%r2(i)%q)
     endif
  enddo
! Max
  do i = 1,ns3d
     ii=ii+1
     if(xst%r3(i)%mykind==r_single)then
        zloc(ii)= maxval(xst%r3(i)%qr4)
     else
        zloc(ii)= maxval(xst%r3(i)%q)
     endif
  enddo
  do i = 1,ns2d
     ii=ii+1
     if(xst%r2(i)%mykind==r_single)then
        zloc(ii)= maxval(xst%r2(i)%qr4)
     else
        zloc(ii)= maxval(xst%r2(i)%q)
     endif
  enddo
  if(ns3d>0)      zloc(3*nvars+1) = real((lat2-2)*(lon2-2)*nsig, r_kind)      ! dim of 3d fields
  if(any(edges))  zloc(3*nvars+2) = real((lat2-2)*(lon2-2)*(nsig+1),r_kind)   ! dim of 3d(edge) fields
  if(ns2d>0)      zloc(3*nvars+3) = real((lat2-2)*(lon2-2), r_kind)           ! dim of 2d fields

! Gather contributions
  call mpi_allgather(zloc,3*nvars+3,mpi_rtype, &
                   & zall,3*nvars+3,mpi_rtype, mpi_comm_world,ierror)

  zz=SUM(zall(3*nvars+1,:))
  ii=0
  do i=1,ns3d
     ii=ii+1
     if(edges(i)) cycle
     psum(ii)=SUM(zall(ii,:))
     pnum(ii)=zz
  enddo
  zz=SUM(zall(3*nvars+2,:))
  ii=0
  do i=1,ns3d
     ii=ii+1
     if(edges(i))then
        psum(ii)=SUM(zall(ii,:))
        pnum(ii)=zz
     endif
  enddo
  zz=SUM(zall(3*nvars+3,:))
  do i=1,ns2d
     ii=ii+1
     psum(ii)=SUM(zall(ii,:))
     pnum(ii)=zz
  enddo
  do ii=1,nvars
     pmin(ii)=MINVAL(zall(  nvars+ii,:))
     pmax(ii)=MAXVAL(zall(2*nvars+ii,:))
  enddo

  return
end subroutine norms_vars
! ----------------------------------------------------------------------
subroutine prt_norms1(xst,sgrep)
!$$$  subprogram documentation block
!                .      .    .                                       .
! subprogram:    prt_norms1
!   prgmmr: j guo
!
! abstract:
!
! program history log:
!   2009-08-12  lueken - added subprogram doc block
!
!   input argument list:
!    xst
!    sgrep
!
!   output argument list:
!
! attributes:
!   language: f90
!   machine:
!
!$$$ end documentation block
  implicit none
  type(gsi_bundle),dimension(:), intent(in   ) :: xst
  character(len=256)          , intent(in   ) :: sgrep

  character(len=8) :: bindx,bform
  character(len=len(sgrep)+len(bindx)+2) :: bgrep
  
  integer(i_kind) :: nx,ix

  nx=size(xst)
  ix=1;
  if(nx>9)    ix=2
  if(nx>99)   ix=3
  if(nx>999)  ix=4
  if(nx>9999) ix=0
  write(bform,'(a,i1,a,i1,a)') '(i',ix,'.',min(ix,2),')'

  do ix=1,nx
     write(bindx,bform) ix
     bindx=adjustl(bindx)
     write(bgrep,'(4a)') trim(sgrep),'(',trim(bindx),')'
     call prt_norms0(xst(ix),trim(bgrep))
  end do
end subroutine prt_norms1
! ----------------------------------------------------------------------
subroutine prt_norms0(xst,sgrep)
!$$$  subprogram documentation block
!                .      .    .                                       .
! subprogram:    prt_norms0
!   prgmmr:
!
! abstract:
!
! program history log:
!   2009-08-12  lueken - added subprogram doc block
!   2010-05-15  todling - update to use gsi_bundle
!
!   input argument list:
!    xst
!    sgrep
!
!   output argument list:
!
! attributes:
!   language: f90
!   machine:
!
!$$$ end documentation block
  implicit none
  type(gsi_bundle), intent(in   ) :: xst
  character(len=*), intent(in   ) :: sgrep

  real(r_kind) :: zmin(nvars),zmax(nvars),zsum(nvars),znum(nvars)
  real(r_kind) :: zavg
  integer(i_kind) :: ii

  call norms_vars(xst,zmin,zmax,zsum,znum)

  if (mype==0) then
     do ii=1,nvars
        zavg=zsum(ii)/znum(ii)
        write(6,999)sgrep,svars(ii),zavg,zmin(ii),zmax(ii)
     enddo
  endif
999 format(A,1X,A,3(1X,ES20.12))

  return
end subroutine prt_norms0
! ----------------------------------------------------------------------
real(r_quad) function dot_prod_st(xst,yst,which)
!$$$  subprogram documentation block
!                .      .    .                                       .
! subprogram:    dot_prod_st
!   prgmmr:
!
! abstract:
!
! program history log:
!   2009-08-12  lueken - added subprogram doc block
!   2010-05-13  todling - update to use gsi_bundle
!   2011-04-28  guo     - bug fix: .not.which was doing (x,x) instead of (x,y)
!
!   input argument list:
!    xst,yst
!    which
!
!   output argument list:
!
! attributes:
!   language: f90
!   machine:
!
!$$$ end documentation block
  implicit none
  type(gsi_bundle)         , intent(in) :: xst, yst
  character(len=*)  ,optional, intent(in) :: which  ! variable name

  real(r_quad),allocatable :: zz(:)
  integer(i_kind) :: i,ii,nv,ipntx,ipnty,irkx,irky,ier,ist

  if (.not.present(which)) then

     nv=nvars
     allocate(zz(nv))
     zz=zero_quad
     ii=0
     do i = 1,ns3d
        ii=ii+1
        if(xst%r3(i)%mykind==r_single .and. yst%r3(i)%mykind==r_single)then
           zz(ii)= dplevs(xst%r3(i)%q,yst%r3(i)%q,ihalo=1)
        else if(xst%r3(i)%mykind==r_double .and. yst%r3(i)%mykind==r_double)then
           zz(ii)= dplevs(xst%r3(i)%q,yst%r3(i)%q,ihalo=1)
        else
           dot_prod_st=zero_quad
           return
        endif
     enddo
     do i = 1,ns2d
        ii=ii+1
        if(xst%r2(i)%mykind==r_single .and. yst%r2(i)%mykind==r_single)then
           zz(ii)= dplevs(xst%r2(i)%qr4,yst%r2(i)%qr4,ihalo=1)
        else if(xst%r2(i)%mykind==r_double .and. yst%r2(i)%mykind==r_double)then
           zz(ii)= dplevs(xst%r2(i)%q,yst%r2(i)%q,ihalo=1)
        else ! this is an error ...
           dot_prod_st=zero_quad
           return
        endif
     enddo

  else

     ier=0
     call gsi_bundlegetpointer(xst,trim(which),ipntx,ist,irank=irkx);ier=ier+ist
     call gsi_bundlegetpointer(yst,trim(which),ipnty,ist,irank=irky);ier=ier+ist
     if(ier/=0) then
        dot_prod_st=zero_quad
        return
     endif

     if(irkx==irky) then

        nv=1
        allocate(zz(nv))
        zz=zero_quad
        if (irkx==2) then
           if(xst%r2(i)%mykind==r_single .and. yst%r2(i)%mykind==r_single) then
              zz(1)=dplevs(xst%r2(ipntx)%qr4,yst%r2(ipnty)%qr4,ihalo=1)
           else if(xst%r2(i)%mykind==r_double .and. yst%r2(i)%mykind==r_double) then
              zz(1)=dplevs(xst%r2(ipntx)%q,yst%r2(ipnty)%q,ihalo=1)
           else ! this is an error
              dot_prod_st=zero_quad
              return
           endif
        endif
        if (irkx==3) then
           if(xst%r3(i)%mykind==r_single .and. yst%r3(i)%mykind==r_single) then
              zz(1)=dplevs(xst%r3(ipntx)%qr4,yst%r3(ipnty)%qr4,ihalo=1)
           else if(xst%r3(i)%mykind==r_double .and. yst%r3(i)%mykind==r_double) then
              zz(1)=dplevs(xst%r3(ipntx)%q,yst%r3(ipnty)%q,ihalo=1)
           else ! this is an error
              dot_prod_st=zero_quad
              return
           endif
        endif

     else
       write(6,*) 'dot_prod_st: improper ranks (x,y)', irkx,irky
       call stop2(999)
     endif

  endif

  call mpl_allreduce(nv,qpvals=zz)

  dot_prod_st=zero_quad
  do ii=1,nv
     dot_prod_st=dot_prod_st+zz(ii)
  enddo

  deallocate(zz)
  return
end function dot_prod_st
function dot_prod_st_r1(xst,yst,which) result(dotprod_)
  use mpeu_util, only: perr,die
  implicit none
  type(gsi_bundle), dimension(:), intent(in) :: xst, yst
  character(len=*), optional    , intent(in) :: which  ! variable component name
  real(r_quad):: dotprod_

  integer(i_kind):: i
  character(len=*),parameter::myname_=myname//'*dot_prod_st_r1'

  dotprod_=0._r_quad
  if(size(xst)/=size(yst)) then
    call perr(myname_,'size(xst)/=size(yst))')
    call perr(myname_,'size(xst) =',size(xst))
    call perr(myname_,'size(yst) =',size(yst))
    call die(myname_)
  endif

  do i=1,size(xst)
    dotprod_=dotprod_+dot_prod_st(xst(i),yst(i),which=which)
  enddo
end function dot_prod_st_r1
! ----------------------------------------------------------------------
subroutine set_random_st ( xst )
!$$$  subprogram documentation block
!                .      .    .                                       .
! subprogram:    set_random_st
!   prgmmr:
!
! abstract:
!
! program history log:
!   2009-08-12  lueken - added subprogram doc block
!   2010-05-15  todling - update to use gsi_bundle
!
!   input argument list:
!    xst
!
!   output argument list:
!    xst
!
! attributes:
!   language: f90
!   machine:
!
!$$$ end documentation block
  implicit none
  type(gsi_bundle), intent(inout) :: xst

  integer(i_kind):: i,ii,jj,iseed,itsn,ip3d,ips,itv,iq,ierror,ier
  integer, allocatable :: nseed(:) ! Intentionaly default integer
  real(r_kind), allocatable :: zz(:)
  real(r_kind), pointer,dimension(:,:,:):: p_tv,p_q,p_p3d,p_tsen
  real(r_kind), pointer,dimension(:,:  ):: p_ps

  iseed=nsig ! just a number
  call random_seed(size=jj)
  allocate(nseed(jj))
  nseed(1:jj)=iseed
! The following because we don't want all procs to get
! exactly the same sequence (which would be repeated in
! the then not so random vector) but it makes the test
! not reproducible if the number of procs is changed.
  nseed(1)=iseed+mype
  call random_seed(put=nseed)
  deallocate(nseed)

  ier=0
  call gsi_bundlegetpointer ( xst, 'p3d' , ip3d, ierror );ier=ierror+ier
  call gsi_bundlegetpointer ( xst, 'tsen', itsn, ierror );ier=ierror+ier
  do i = 1,ns3d
     if (i/=ip3d.and.i/=itsn) then ! Physical consistency
         if(xst%r3(i)%mykind==r_single) then
           call random_number ( xst%r3(i)%qr4 )
         else
           call random_number ( xst%r3(i)%q )
         endif
     endif
  enddo
  do i = 1,ns2d
     if(xst%r2(i)%mykind==r_single) then
        call random_number ( xst%r2(i)%qr4 )
     else
        call random_number ( xst%r2(i)%q )
     endif
  enddo

! There must be physical consistency when creating random vectors

  ier=0
  call gsi_bundlegetpointer ( xst, 'ps'  , p_ps,  ierror );ier=ierror+ier
  call gsi_bundlegetpointer ( xst, 'tv'  , p_tv,  ierror );ier=ierror+ier
  call gsi_bundlegetpointer ( xst, 'q'   , p_q ,  ierror );ier=ierror+ier
  call gsi_bundlegetpointer ( xst, 'p3d' , p_p3d ,ierror );ier=ierror+ier
  call gsi_bundlegetpointer ( xst, 'tsen', p_tsen,ierror );ier=ierror+ier

! There must be physical consistency when creating random vectors
  if (ier==0) then
      call getprs_tl (p_ps,p_tv,p_p3d)
      call tv_to_tsen(p_tv,p_q,p_tsen)
  endif

return
end subroutine set_random_st
! ----------------------------------------------------------------------
subroutine inquire_state
!$$$  subprogram documentation block
!                .      .    .                                       .
! subprogram:    inquire_state
!   prgmmr:
!
! abstract:
!
! program history log:
!   2009-08-12  lueken - added subprogram doc block
!
!   input argument list:
!
!   output argument list:
!
! attributes:
!   language: f90
!   machine:
!
!$$$ end documentation block
implicit none
real(r_kind) :: zz

if (mype==0) then
   write(6,*)'state_vectors: latlon11,latlon1n,latlon1n1,lat2,lon2,nsig=', &
                             latlon11,latlon1n,latlon1n1,lat2,lon2,nsig
   zz=real(max_st_alloc*nval_len,r_kind)*8.0_r_kind/1.048e6_r_kind
   write(6,*)'state_vectors: length=',nval_len
   write(6,*)'state_vectors: currently allocated=',m_st_alloc
   write(6,*)'state_vectors: maximum allocated=',max_st_alloc
   write(6,*)'state_vectors: number of allocates=',m_allocs
   write(6,*)'state_vectors: number of deallocates=',m_deallocs
   write(6,'(A,F8.1,A)')'state_vectors: Estimated max memory used= ',zz,' Mb'
endif

end subroutine inquire_state
! ----------------------------------------------------------------------
end module state_vectors
