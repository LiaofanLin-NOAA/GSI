module crtm_interface
!$$$ module documentation block
!           .      .    .                                       .
! module:   crtm_interface module for setuprad. Calculates profile and calls crtm
!  prgmmr:
!
! abstract: crtm_interface module for setuprad. Initializes CRTM, Calculates profile and 
!         calls CRTM and destroys initialization
!
! program history log:
!   2010-08-17  Derber - initial creation from intrppx
!   2011-05-06  merkova/todling - add use of q-clear calculation for AIRS
!   2011-04-08  li     - (1) Add nst_gsi, itref,idtw, idtc, itz_tr to apply NSST. 
!                      - (2) Use Tz instead of Ts as water surface temperature when nst_gsi > 1
!                      - (3) add tzbgr as one of the out dummy variable
!                      - (4) Include tz_tr in ts calculation over water
!                      - (5) Change minmum temperature of water surface from 270.0 to 271.0
!   2011-07-04  todling - fixes to run either single or double precision
!   2011-09-20  hclin  - modified for modis_aod
!                        (1) The jacobian of wrfchem/gocart p25 species (not calculated in CRTM)
!                            is derived from dust1 and dust2
!                        (2) skip loading geometry and surface structures for modis_aod
!                        (3) separate jacobian calculation for modis_aod
!
! subroutines included:
!   sub init_crtm
!   sub call_crtm
!   sub destroy_crtm
!
! attributes:
!   language: f90
!   machine:
!
!$$$ end documentation block

use kinds,only: r_kind,i_kind,r_single
use type_kinds, only: crtm_kind => fp
use crtm_module, only: crtm_atmosphere_type,crtm_surface_type,crtm_geometry_type, &
    crtm_options_type,crtm_rtsolution_type,crtm_destroy,crtm_options_destroy, &
    crtm_options_create,crtm_options_associated,success,crtm_atmosphere_create, &
    crtm_surface_create,crtm_k_matrix
use crtm_module, only: urban_concrete,compacted_soil,irrigated_low_vegetation,grass_soil,meadow_grass
use crtm_module, only: broadleaf_forest,pine_forest,tundra,irrigated_low_vegetation,wet_soil
use crtm_module, only: broadleaf_pine_forest,pine_forest,tundra,irrigated_low_vegetation,wet_soil
use crtm_module, only: scrub,tilled_soil,scrub_soil,broadleaf_brush,grass_scrub,invalid_land
use crtm_channelinfo_define, only: crtm_channelinfo_type
use crtm_surface_define, only: crtm_surface_destroy, crtm_surface_associated, crtm_surface_zero
use crtm_atmosphere_define, only:crtm_atmosphere_associated, &
    crtm_atmosphere_destroy,crtm_atmosphere_zero
use crtm_rtsolution_define, only: crtm_rtsolution_type, crtm_rtsolution_create, &
    crtm_rtsolution_destroy, crtm_rtsolution_associated
use gridmod, only: lat2,lon2,nsig,msig,nvege_type,regional
use mpeu_util, only: die
!nesdis_crtm_aod use crtm_aod_module, only: crtm_aod_k

implicit none

private
public init_crtm            ! Subroutine initializes crtm for specified instrument
public call_crtm            ! Subroutine creates profile for crtm, calls crtm, then adjoint of create
public destroy_crtm         ! Subroutine destroys initialization for crtm
public sensorindex
public surface
public isatid               ! = 1  index of satellite id
public itime                ! = 2  index of analysis relative obs time
public ilon                 ! = 3  index of grid relative obs location (x)
public ilat                 ! = 4  index of grid relative obs location (y)
public ilzen_ang            ! = 5  index of local (satellite) zenith angle (radians)
public ilazi_ang            ! = 6  index of local (satellite) azimuth angle (radians)
public iscan_ang            ! = 7  index of scan (look) angle (radians)
public iscan_pos            ! = 8  index of integer scan position
public iszen_ang            ! = 9  index of solar zenith angle (degrees)
public isazi_ang            ! = 10 index of solar azimuth angle (degrees)
public ifrac_sea            ! = 11 index of ocean percentage
public ifrac_lnd            ! = 12 index of land percentage
public ifrac_ice            ! = 13 index of ice percentage
public ifrac_sno            ! = 14 index of snow percentage
public its_sea              ! = 15 index of ocean temperature
public its_lnd              ! = 16 index of land temperature
public its_ice              ! = 17 index of ice temperature
public its_sno              ! = 18 index of snow temperature
public itsavg               ! = 19 index of average temperature
public ivty                 ! = 20 index of vegetation type
public ivfr                 ! = 21 index of vegetation fraction
public isty                 ! = 22 index of soil type
public istp                 ! = 23 index of soil temperature
public ism                  ! = 24 index of soil moisture
public isn                  ! = 25 index of snow depth
public izz                  ! = 26 index of surface height
public idomsfc              ! = 27 index of dominate surface type
public isfcr                ! = 28 index of surface roughness
public iff10                ! = 29 index of ten meter wind factor
public ilone                ! = 30 index of earth relative longitude (degrees)
public ilate                ! = 31 index of earth relative latitude (degrees)
public iclr_sky             ! = 7  index of clear sky amount (goes_img, seviri)
public isst_navy            ! = 7  index of navy sst retrieval (K) (avhrr_navy)
public idata_type           ! = 32 index of data type (151=day, 152=night, avhrr_navy)
public iclavr               ! = 32 index of clavr cloud flag (avhrr)
public isst_hires           ! = 33 index of interpolated hires sst
public itref                ! = 34/36 index of Tr
public idtw                 ! = 35/37 index of d(Tw)
public idtc                 ! = 36/38 index of d(Tc)
public itz_tr               ! = 37/39 index of d(Tz)/d(Tr)
 
!  Note other module variables are only used within this routine

  character(len=*), parameter :: myname='crtm_interface'

  character(len=20),save,allocatable,dimension(:)   :: aero_names   ! aerosol names
  real(r_kind)   , save ,allocatable,dimension(:,:) :: aero         ! aerosol (guess) profiles at obs location
  real(r_kind)   , save ,allocatable,dimension(:,:) :: aero_conc    ! aerosol (guess) concentrations at obs location
  real(r_kind)   , save ,allocatable,dimension(:)   :: auxrh        ! temporary array for rh profile as seen by CRTM

  character(len=20),save,allocatable,dimension(:)   :: cloud_names  ! cloud names
  integer(i_kind), save ,allocatable,dimension(:)   :: jcloud       ! cloud index for those fed to CRTM
  real(r_kind)   , save ,allocatable,dimension(:,:) :: cloud        ! cloud considered here
  real(r_kind)   , save ,allocatable,dimension(:,:) :: cloud_cont   ! cloud content fed into CRTM 

  real(r_kind)   , save ,allocatable,dimension(:,:,:,:)  :: gesqsat ! qsat to calc rh for aero particle size estimate

  integer(i_kind),save, allocatable,dimension(:) :: nmm_to_crtm
  integer(i_kind),save, allocatable,dimension(:) :: icw
  integer(i_kind),save, allocatable,dimension(:) :: iaero_jac
  integer(i_kind),save :: isatid,itime,ilon,ilat,ilzen_ang,ilazi_ang,iscan_ang
  integer(i_kind),save :: iscan_pos,iszen_ang,isazi_ang,ifrac_sea,ifrac_lnd,ifrac_ice
  integer(i_kind),save :: ifrac_sno,its_sea,its_lnd,its_ice,its_sno,itsavg
  integer(i_kind),save :: ivty,ivfr,isty,istp,ism,isn,izz,idomsfc,isfcr,iff10,ilone,ilate
  integer(i_kind),save :: iclr_sky,isst_navy,idata_type,isst_hires,iclavr
  integer(i_kind),save :: itref,idtw,idtc,itz_tr
  integer(i_kind),save :: sensorindex
  integer(i_kind),save :: ico2,ier
  integer(i_kind),save :: n_aerosols_jac     ! number of aerosols in jocabian
  integer(i_kind),save :: n_aerosols         ! number of aerosols considered
  integer(i_kind),save :: n_aerosols_crtm    ! number of aerosols seen by CRTM
  integer(i_kind),save :: n_clouds_jac       ! number of clouds in jacobian
  integer(i_kind),save :: n_actual_clouds    ! number of clouds considered by this interface
  integer(i_kind),save :: n_clouds           ! number of clouds seen by CRTM
  integer(i_kind),save :: icf
  integer(i_kind),save :: itv,iqv,ioz,ius,ivs,isst
  integer(i_kind),save :: ip25, indx_p25, indx_dust1, indx_dust2
  logical        ,save :: lcf4crtm
  logical        ,save :: lcw4crtm

  type(crtm_atmosphere_type),save,dimension(1)   :: atmosphere
  type(crtm_surface_type),save,dimension(1)      :: surface
  type(crtm_geometry_type),save,dimension(1)     :: geometryinfo
  type(crtm_options_type),save,dimension(1)      :: options
  type(crtm_channelinfo_type),save,dimension(1)  :: channelinfo


  type(crtm_atmosphere_type),save,allocatable,dimension(:,:):: atmosphere_k
  type(crtm_surface_type),save,allocatable,dimension(:,:):: surface_k
  type(crtm_rtsolution_type),save,allocatable,dimension(:,:):: rtsolution
  type(crtm_rtsolution_type),save,allocatable,dimension(:,:):: rtsolution_k

! Mapping land surface type of GFS to CRTM
!  Note: index 0 is water, and index 13 is ice. The two indices are not
!        used and just assigned to COMPACTED_SOIL.
  integer(i_kind), parameter, dimension(0:13) :: gfs_to_crtm=(/COMPACTED_SOIL, &
     BROADLEAF_FOREST, BROADLEAF_FOREST, BROADLEAF_PINE_FOREST, PINE_FOREST, &
     PINE_FOREST, BROADLEAF_BRUSH, SCRUB, SCRUB, SCRUB_SOIL, TUNDRA, &
     COMPACTED_SOIL, TILLED_SOIL, COMPACTED_SOIL/)

contains
subroutine init_crtm(init_pass,mype_diaghdr,mype,nchanl,isis,obstype)
!$$$  subprogram documentation block
!                .      .    .                                       .
! subprogram:    init_crtm initializes things for use with call to crtm from setuprad
!
!   prgmmr: derber           org: np2                 date: 2010-08-17
!
! abstract: initialize things for use with call to crtm from setuprad.   
!
! program history log:
!   2010-08-17  derber  
!   2011-02-16  todling - add calculation of rh when aerosols are available
!   2011-05-03  todling - merge with Min-Jeong's MW cloudy radiance; combine w/ metguess
!   2011-05-20  mccarty - add atms wmo_sat_id hack (currently commented out)
!
!   input argument list:
!     init_pass    - state of "setup" processing
!     mype_diaghdr - processor to produce output from crtm
!     mype         - current processor        
!     nchanl       - number of channels    
!     isis         - instrument/sensor character string 
!     obstype      - observation type
!
!   output argument list:
!
! attributes:
!   language: f90
!   machine:  ibm RS/6000 SP
!
!$$$

  use gsi_bundlemod, only: gsi_bundlegetpointer
  use gsi_chemguess_mod, only: gsi_chemguess_bundle   ! for now, a common block
  use gsi_chemguess_mod, only: gsi_chemguess_get
  use gsi_metguess_mod,  only: gsi_metguess_bundle    ! for now, a common block
  use gsi_metguess_mod,  only: gsi_metguess_get
  use crtm_module, only: mass_mixing_ratio_units,co2_id,o3_id,crtm_init
  use crtm_parameters, only: toa_pressure,max_n_layers
  use crtm_atmosphere_define, only: volume_mixing_ratio_units,h2o_id
  use radinfo, only: crtm_coeffs_path
  use radinfo, only: radjacindxs,radjacnames
  use aeroinfo, only: aerojacindxs,aerojacnames
  use guess_grids, only: ges_tsen,ges_q,ges_prsl,nfldsig
  use mpeu_util, only: getindex
  use constants, only: tiny_r_kind

  implicit none

  integer(i_kind),intent(in) :: nchanl,mype_diaghdr,mype
  character(20)  ,intent(in) :: isis
  character(10)  ,intent(in) :: obstype
  logical        ,intent(in) :: init_pass

  character(len=*), parameter :: myname_=myname//'crtm_interface'
  integer(i_kind) ier,ii,error_status,iderivative
  logical ice,Load_AerosolCoeff,Load_CloudCoeff
  integer(i_kind),parameter::  n_absorbers = 3
  character(len=20),dimension(1):: sensorlist
  integer(i_kind) icf4crtm,icw4crtm,indx,iii,icloud4crtm

  isst=-1
  ivs=-1
  ius=-1
  ioz=-1
  iqv=-1
  itv=-1
! Get indexes of variables composing the jacobian
  indx =getindex(radjacnames,'tv')
  if(indx>0) itv=radjacindxs(indx)
  indx =getindex(radjacnames,'q' )
  if(indx>0) iqv=radjacindxs(indx)
  indx =getindex(radjacnames,'oz')
  if(indx>0) ioz=radjacindxs(indx)
  indx =getindex(radjacnames,'u')
  if(indx>0) ius=radjacindxs(indx)
  indx =getindex(radjacnames,'v')
  if(indx>0) ivs=radjacindxs(indx)
  indx=getindex(radjacnames,'sst')
  if(indx>0) isst=radjacindxs(indx)

  call gsi_metguess_get ( 'clouds::3d', n_clouds, ier )
  allocate(cloud_names(max(n_clouds,1)))
  call gsi_metguess_get ('clouds::3d',cloud_names,ier)
  n_clouds_jac=0
  do ii=1,n_clouds
     indx=getindex(radjacnames,trim(cloud_names(ii)))
     if(indx>0) n_clouds_jac=n_clouds_jac+1
  end do
  allocate(icw(max(n_clouds_jac,1)))
  icw=-1
  n_clouds_jac=0
  do ii=1,n_clouds
     indx=getindex(radjacnames,trim(cloud_names(ii)))
     if(indx>0) then
        n_clouds_jac=n_clouds_jac+1
        icw(n_clouds_jac)=radjacindxs(indx)
     endif
  end do
  deallocate(cloud_names)

! Get indexes of variables composing the jacobian_aero
  n_aerosols=0
  n_aerosols_jac=0
  call gsi_chemguess_get ( 'aerosols::3d', n_aerosols, ier )
  if (n_aerosols > 0) then
     allocate(aero_names(n_aerosols))
     call gsi_chemguess_get ('aerosols::3d',aero_names,ier)
     indx_p25   = getindex(aero_names,'p25')
     indx_dust1 = getindex(aero_names,'dust1')
     indx_dust2 = getindex(aero_names,'dust2')
     do ii=1,n_aerosols
        indx=getindex(aerojacnames,trim(aero_names(ii)))
        if(indx>0) n_aerosols_jac=n_aerosols_jac+1
     end do
     if (n_aerosols_jac >0) then
        allocate(iaero_jac(n_aerosols_jac))
        iaero_jac=-1
        n_aerosols_jac=0
        do ii=1,n_aerosols
           indx=getindex(aerojacnames,trim(aero_names(ii)))
           if(indx>0) then
              n_aerosols_jac=n_aerosols_jac+1
              iaero_jac(n_aerosols_jac)=aerojacindxs(indx)
           endif
        end do
     endif
     deallocate(aero_names)
  endif

! Inquire presence of extra fields in MetGuess
 icf=-1; icf4crtm=-1
 if (size(gsi_metguess_bundle)>0) then ! check to see if bundle's allocated
!   get cloud-fraction for radiation information
    call gsi_bundlegetpointer(gsi_metguess_bundle(1),'cf',icf,ier)
    call gsi_metguess_get ( 'i4crtm::cf', icf4crtm, ier )
 endif
 lcf4crtm = obstype=='airs' .and. icf4crtm==12 .and. icf>0

! When CW is available in MetGuess, defined Cloudy Radiance for MW only
 lcw4crtm=.false.
 if(trim(obstype)=='amsua') then
!   get cloud-condensate information
    call gsi_metguess_get ( 'clouds_4crtm::3d', n_actual_clouds, ier )
    n_clouds=n_actual_clouds
    if(n_actual_clouds>0) then
       call gsi_metguess_get ( 'i4crtm::cw', icw4crtm, ier )
       if (icw4crtm==12) then 
           if (n_clouds==1) then
               n_clouds=n_clouds+1
               lcw4crtm=.true.
           else
               call die(myname_,'cannot split cw when more than single cloud available',99)
           endif
       endif

       allocate(cloud_cont(msig,n_clouds))
       allocate(jcloud(n_clouds))
       allocate(cloud_names(n_actual_clouds))
       allocate(cloud(nsig,n_actual_clouds))

       call gsi_metguess_get ('clouds_4crtm::3d',cloud_names,ier)

       if (.not.lcw4crtm) then
          iii=0
          do ii=1,n_actual_clouds
             call gsi_metguess_get ( 'i4crtm::'//trim(cloud_names(ii)), icloud4crtm, ier )
             if (icloud4crtm==12) then
                iii=iii+1
                jcloud(iii)=ii
             endif
          end do
          if(iii/=n_clouds) call die(myname_,'inconsistent cloud count',99)
       endif

       Load_CloudCoeff = .true.
    else
       n_actual_clouds = 0
       n_clouds = n_actual_clouds
       Load_CloudCoeff = .false.
    endif
 else
    n_actual_clouds = 0
    n_clouds = n_actual_clouds
    Load_CloudCoeff = .false.
 endif

! Set up index for input satellite data array

 isatid    = 1  ! index of satellite id
 itime     = 2  ! index of analysis relative obs time
 ilon      = 3  ! index of grid relative obs location (x)
 ilat      = 4  ! index of grid relative obs location (y)
 ilzen_ang = 5  ! index of local (satellite) zenith angle (radians)
 ilazi_ang = 6  ! index of local (satellite) azimuth angle (radians)
 iscan_ang = 7  ! index of scan (look) angle (radians)
 iscan_pos = 8  ! index of integer scan position
 iszen_ang = 9  ! index of solar zenith angle (degrees)
 isazi_ang = 10 ! index of solar azimuth angle (degrees)
 ifrac_sea = 11 ! index of ocean percentage
 ifrac_lnd = 12 ! index of land percentage
 ifrac_ice = 13 ! index of ice percentage
 ifrac_sno = 14 ! index of snow percentage
 its_sea   = 15 ! index of ocean temperature
 its_lnd   = 16 ! index of land temperature
 its_ice   = 17 ! index of ice temperature
 its_sno   = 18 ! index of snow temperature
 itsavg    = 19 ! index of average temperature
 ivty      = 20 ! index of vegetation type
 ivfr      = 21 ! index of vegetation fraction
 isty      = 22 ! index of soil type
 istp      = 23 ! index of soil temperature
 ism       = 24 ! index of soil moisture
 isn       = 25 ! index of snow depth
 izz       = 26 ! index of surface height
 idomsfc   = 27 ! index of dominate surface type
 isfcr     = 28 ! index of surface roughness
 iff10     = 29 ! index of ten meter wind factor
 ilone     = 30 ! index of earth relative longitude (degrees)
 ilate     = 31 ! index of earth relative latitude (degrees)
 itref     = 34 ! index of foundation temperature: Tr
 idtw      = 35 ! index of diurnal warming: d(Tw) at depth zob
 idtc      = 36 ! index of sub-layer cooling: d(Tc) at depth zob
 itz_tr    = 37 ! index of d(Tz)/d(Tr)

 if ( obstype == 'avhrr_navy' .or. obstype == 'avhrr' ) then         ! when an independent SST analysis is read in
   itref     = 36 ! index of foundation temperature: Tr
   idtw      = 37 ! index of diurnal warming: d(Tw) at depth zob
   idtc      = 38 ! index of sub-layer cooling: d(Tc) at depth zob
   itz_tr    = 39 ! index of d(Tz)/d(Tr)
 endif


 if (obstype == 'goes_img') then
    iclr_sky      =  7 ! index of clear sky amount
 elseif (obstype == 'avhrr_navy') then
    isst_navy     =  7 ! index of navy sst (K) retrieval
    idata_type    = 32 ! index of data type (151=day, 152=night)
    isst_hires    = 33 ! index of interpolated hires sst (K)
 elseif (obstype == 'avhrr') then
    iclavr        = 32 ! index CLAVR cloud flag with AVHRR data
    isst_hires    = 33 ! index of interpolated hires sst (K)
 elseif (obstype == 'seviri') then
    iclr_sky      =  7 ! index of clear sky amount
 endif

! Get pointer to CO2
! NOTE: for now, not to rock the boat, this takes CO2 from 1st time slot
!       eventually this could do the time interpolation by taking CO2 from
!       two proper time slots.

 ico2=-1
 if(size(gsi_chemguess_bundle)>0) & ! check to see if bundle's allocated
 call gsi_bundlegetpointer(gsi_chemguess_bundle(1),'co2',ico2,ier)

! Are there aerosols to affect CRTM?

 call gsi_chemguess_get ('aerosols_4crtm::3d',n_aerosols_crtm,ier)
 ip25 = -1
 if (n_aerosols_crtm>0) then
    call gsi_bundlegetpointer(gsi_chemguess_bundle(1),'p25',ip25,ier)
    if ( ip25 > 0 ) then
       n_aerosols = n_aerosols_crtm + 1
    else
       n_aerosols = n_aerosols_crtm
    endif
 endif
 if(n_aerosols>0)then
    allocate(aero(nsig,n_aerosols),aero_conc(msig,n_aerosols),auxrh(msig))
    allocate(aero_names(n_aerosols))
    call gsi_chemguess_get ('aerosols::3d',aero_names,ier)

    Load_AerosolCoeff=.true.
 else
    n_aerosols=0
    Load_AerosolCoeff=.false.
 endif


! Initialize radiative transfer

 sensorlist(1)=isis
 if( crtm_coeffs_path /= "" ) then
    if(init_pass .and. mype==mype_diaghdr) write(6,*)'INIT_CRTM: crtm_init() on path "'//trim(crtm_coeffs_path)//'"'
    error_status = crtm_init(sensorlist,channelinfo,&
       Process_ID=mype,Output_Process_ID=mype_diaghdr, &
       Load_CloudCoeff=Load_CloudCoeff,Load_AerosolCoeff=Load_AerosolCoeff, &
       File_Path = crtm_coeffs_path )
 else
    error_status = crtm_init(sensorlist,channelinfo,&
       Process_ID=mype,Output_Process_ID=mype_diaghdr, &
       Load_CloudCoeff=Load_CloudCoeff,Load_AerosolCoeff=Load_AerosolCoeff)
 endif
 if (error_status /= success) then
    write(6,*)'INIT_CRTM:  ***ERROR*** crtm_init error_status=',error_status,&
       '   TERMINATE PROGRAM EXECUTION'
    call stop2(71)
 endif

 sensorindex = 0

! temporary hardcoded declaration of NPP Sat ID.  Dies later because this is read 
!    from TauCoeff, where it is currently undefined. -wm
! 5/20 Update: Commented out for the time being w/ new atms_npp coef files, will
!    remove later -wm
! if (trim(isis) == 'atms_c1') channelinfo(1)%WMO_Satellite_ID = 224

! determine specific sensor
! Added a fudge in here to prevent multiple script changes following change of AIRS naming
! convention in CRTM.

 if (channelinfo(1)%sensor_id == isis .OR. &
    (channelinfo(1)%sensor_id == 'airs281_aqua' .AND. &
    isis == 'airs281SUBSET_aqua')) sensorindex = 1
 if (sensorindex == 0 ) then
    write(6,*)'INIT_CRTM:  ***WARNING*** problem with sensorindex=',isis,&
       ' --> CAN NOT PROCESS isis=',isis,'   TERMINATE PROGRAM EXECUTION found ',&
       channelinfo(1)%sensor_id
    call stop2(71)
 endif

! Check for consistency between user specified number of channels (nchanl)
! and those defined by CRTM channelinfo structure.   Return to calling
! routine if there is a mismatch.

 if (nchanl /= channelinfo(sensorindex)%n_channels) then
    write(6,*)'INIT_CRTM:  ***WARNING*** mismatch between nchanl=',&
       nchanl,' and n_channels=',channelinfo(sensorindex)%n_channels,&
       ' --> CAN NOT PROCESS isis=',isis,'   TERMINATE PROGRAM EXECUTION'
    call stop2(71)
 endif

! Allocate structures for radiative transfer

 allocate(&
    rtsolution  (channelinfo(sensorindex)%n_channels,1),&
    rtsolution_k(channelinfo(sensorindex)%n_channels,1),&
    atmosphere_k(channelinfo(sensorindex)%n_channels,1),&
    surface_k   (channelinfo(sensorindex)%n_channels,1))

!  Check to ensure that number of levels requested does not exceed crtm max

 if(msig > max_n_layers)then
    write(6,*) 'INIT_CRTM:  msig > max_n_layers - increase crtm max_n_layers ',&
       msig,max_n_layers
    call stop2(36)
 end if

!  Create structures for radiative transfer

 call crtm_atmosphere_create(atmosphere(1),msig,n_absorbers,n_clouds,n_aerosols_crtm)
!_RTod-NOTE if(r_kind==r_single .and. crtm_kind/=r_kind) then ! take care of case: GSI(single); CRTM(double)
!_RTod-NOTE    call crtm_surface_create(surface(1),channelinfo(sensorindex)%n_channels,tolerance=1.0e-5_crtm_kind)
!_RTod-NOTE else
!_RTod-NOTE: the following will work in single precision but issue lots of msg and remove more obs than needed
    call crtm_surface_create(surface(1),channelinfo(sensorindex)%n_channels)
!_RTod-NOTE endif
 call crtm_rtsolution_create(rtsolution,msig)
 call crtm_rtsolution_create(rtsolution_k,msig)
 call crtm_options_create(options,nchanl)

 if (.NOT.(crtm_atmosphere_associated(atmosphere(1)))) &
    write(6,*)' ***ERROR** creating atmosphere.'
 if (.NOT.(crtm_surface_associated(surface(1)))) &
    write(6,*)' ***ERROR** creating surface.'
 if (.NOT.(ANY(crtm_rtsolution_associated(rtsolution)))) &
    write(6,*)' ***ERROR** creating rtsolution.'
 if (.NOT.(ANY(crtm_rtsolution_associated(rtsolution_k)))) &
    write(6,*)' ***ERROR** creating rtsolution_k.'
 if (.NOT.(ANY(crtm_options_associated(options)))) &
    write(6,*)' ***ERROR** creating options.'

! Turn off antenna correction

 options(1)% use_antenna_correction = .false.

! Check for consistency with information in crtm for number of channels

 if(nchanl /= channelinfo(sensorindex)%n_channels) write(6,*)'***ERROR** nchanl,n_channels ', &
    nchanl,channelinfo(sensorindex)%n_channels

! Load surface sensor data structure

 surface(1)%sensordata%n_channels = channelinfo(sensorindex)%n_channels

!! REL-1.2 CRTM
!!  surface(1)%sensordata%select_wmo_sensor_id  = channelinfo(1)%wmo_sensor_id
!! RB-1.1.rev1855 CRTM

 surface(1)%sensordata%sensor_id             =  channelinfo(sensorindex)%sensor_id
 surface(1)%sensordata%WMO_sensor_id         =  channelinfo(sensorindex)%WMO_sensor_id
 surface(1)%sensordata%WMO_Satellite_id      =  channelinfo(sensorindex)%WMO_Satellite_id
 surface(1)%sensordata%sensor_channel        =  channelinfo(sensorindex)%sensor_channel


 atmosphere(1)%n_layers = msig
!  atmosphere%level_temperature_input = 0
 atmosphere(1)%absorber_id(1) = H2O_ID
 atmosphere(1)%absorber_id(2) = O3_ID
 atmosphere(1)%absorber_id(3) = CO2_ID
 atmosphere(1)%absorber_units(1) = MASS_MIXING_RATIO_UNITS
 atmosphere(1)%absorber_units(2) = VOLUME_MIXING_RATIO_UNITS
 atmosphere(1)%absorber_units(3) = VOLUME_MIXING_RATIO_UNITS
 atmosphere(1)%level_pressure(0) = TOA_PRESSURE

!  Allocate structure for _k arrays (jacobians)

 do ii=1,nchanl

    atmosphere_k(ii,1) = atmosphere(1)
    surface_k(ii,1)   = surface(1)

 end do

! Mapping land surface type of NMM to CRTM
 if (regional) then
    allocate(nmm_to_crtm(nvege_type) )

    if(nvege_type==24)then
!    Note: index 16 is water, and index 24 is ice. The two indices are not
!          used and just assigned to COMPACTED_SOIL.
       nmm_to_crtm=(/URBAN_CONCRETE, &
          COMPACTED_SOIL, IRRIGATED_LOW_VEGETATION, GRASS_SOIL, MEADOW_GRASS, &
          MEADOW_GRASS, MEADOW_GRASS, SCRUB, GRASS_SCRUB, MEADOW_GRASS, &
          BROADLEAF_FOREST, PINE_FOREST, BROADLEAF_FOREST, PINE_FOREST, &
          BROADLEAF_PINE_FOREST, COMPACTED_SOIL, WET_SOIL, WET_SOIL, &
          IRRIGATED_LOW_VEGETATION, TUNDRA, TUNDRA, TUNDRA, TUNDRA, &
          COMPACTED_SOIL/)
    else if(nvege_type==20)then
       nmm_to_crtm=(/PINE_FOREST, &
          BROADLEAF_FOREST, PINE_FOREST, BROADLEAF_FOREST, &
          BROADLEAF_PINE_FOREST, SCRUB, SCRUB_SOIL, BROADLEAF_BRUSH, &
          BROADLEAF_BRUSH, SCRUB, BROADLEAF_BRUSH, TILLED_SOIL, URBAN_CONCRETE, &
          TILLED_SOIL, INVALID_LAND, COMPACTED_SOIL, INVALID_LAND, TUNDRA, &
          TUNDRA, TUNDRA/)
    else
       write(6,*)'SETUPRAD:  ***ERROR*** invalid number of vegetation types', &
          ' (only 20 and 24 are setup)  nvege_type=',nvege_type, &
          '  ***STOP IN SETUPRAD***'
       call stop2(71)
    endif ! nvege_type
 endif ! regional

! Calculate RH when aerosols are present and/or cloud-fraction used
 if (n_aerosols>0 .or. lcf4crtm) then
    allocate(gesqsat(lat2,lon2,nsig,nfldsig))
    ice=.true.
    iderivative=0
    do ii=1,nfldsig
       call genqsat(gesqsat(1,1,1,ii),ges_tsen(1,1,1,ii),ges_prsl(1,1,1,ii),lat2,lon2,nsig,ice,iderivative)
    end do
 endif

 return
end subroutine init_crtm
subroutine destroy_crtm
!$$$  subprogram documentation block
!                .      .    .                                       .
! subprogram:    destroy_crtm  deallocates crtm arrays
!   prgmmr: parrish          org: np22                date: 2005-01-22
!
! abstract: deallocates crtm arrays
!
! program history log:
!   2010-08-17  derber 
!
!   input argument list:
!
!   output argument list:
!
! attributes:
!   language: f90
!   machine:  ibm RS/6000 SP
!
!$$$
  implicit none

  integer(i_kind) error_status

  error_status = crtm_destroy(channelinfo)
  if (error_status /= success) &
     write(6,*)'OBSERVER:  ***ERROR*** crtm_destroy error_status=',error_status
  if (n_aerosols>0 .or. lcf4crtm) then
     deallocate(gesqsat)
  endif
  call crtm_atmosphere_destroy(atmosphere(1))
  call crtm_surface_destroy(surface(1))
  call crtm_rtsolution_destroy(rtsolution)
  call crtm_rtsolution_destroy(rtsolution_k)
  call crtm_options_destroy(options)
  if (crtm_atmosphere_associated(atmosphere(1))) &
     write(6,*)' ***ERROR** destroying atmosphere.'
  if (crtm_surface_associated(surface(1))) &
     write(6,*)' ***ERROR** destroying surface.'
  if (ANY(crtm_rtsolution_associated(rtsolution))) &
     write(6,*)' ***ERROR** destroying rtsolution.'
  if (ANY(crtm_rtsolution_associated(rtsolution_k))) &
     write(6,*)' ***ERROR** destroying rtsolution_k.'
  if (ANY(crtm_options_associated(options))) &
     write(6,*)' ***ERROR** destroying options.'
  deallocate(rtsolution,atmosphere_k,surface_k,rtsolution_k)
  if(n_aerosols>0)then
     deallocate(aero_names)
     deallocate(aero,aero_conc,auxrh)
  endif
  if(n_clouds>0)then
     deallocate(cloud)
     deallocate(cloud_names)
     deallocate(jcloud)
     deallocate(cloud_cont)
  endif
  deallocate(icw)
  if(regional)deallocate(nmm_to_crtm)

  return
end subroutine destroy_crtm
subroutine call_crtm(obstype,obstime,data_s,nchanl,nreal,ich, &
                   h,q,clw_guess,prsl,prsi, &
                   trop5,tzbgr,dtsavg,sfc_speed,&
                   tsim,emissivity,ptau5,ts, &
                   emissivity_k,temp,wmix,jacobian,error_status, &
                   layer_od,jacobian_aero)
!$$$  subprogram documentation block
!                .      .    .                                       .
! subprogram:    call_crtm   creates vertical profile of t,q,oz,p,zs,etc., 
!             calls crtm, and does adjoint of creation (where necessary) for setuprad    
!   prgmmr: parrish          org: np22                date: 1990-10-11
!
! abstract: creates vertical profile of t,q,oz,p,zs,etc., 
!             calls crtm, and does adjoint of creation (where necessary) for setuprad
!
! program history log:
!   2010-08-17  derber - modify from intrppx and add threading
!   2011-02-23  todling/da silva - revisit interface to fill in aerosols
!   2011-05-03  todling - merge with Min-Jeong's MW cloudy radiance; combine w/ metguess
!                         (did not include tendencies since they were calc but not used)
!   2011-05-17  auligne/todling - add handling for hydrometeors
!   2011-06-29  todling - no explict reference to internal bundle arrays
!
!   input argument list:
!     obstype      - type of observations for which to get profile
!     obstime      - time of observations for which to get profile
!     data_s       - array containing input data information
!     nchanl       - number of channels
!     nreal        - number of descriptor information in data_s
!     ich          - channel number array
!
!   output argument list:
!     h            - interpolated temperature
!     q            - interpolated specific humidity (max(qsmall,q))
!     prsl         - interpolated layer pressure (nsig)
!     prsi         - interpolated level pressure (nsig+1)
!     trop5        - interpolated tropopause pressure
!     tzbgr        - water surface temperature used in Tz retrieval
!     dtsavg       - delta average skin temperature over surface types
!     uu5          - interpolated bottom sigma level zonal wind    
!     vv5          - interpolated bottom sigma level meridional wind  
!     tsim         - simulated brightness temperatures
!     emissivity   - surface emissivities
!     ptau5        - level transmittances
!     ts           - skin temperature sensitivities
!     emissivity_k - surface emissivity sensitivities             
!     temp         - temperature sensitivities
!     wmix         - humidity sensitivities
!     jacobian     - nsigradjac level jacobians for use in intrad and stprad
!     error_status - error status from crtm
!     layer_od     - layer optical depth
!     jacobian_aero- nsigaerojac level jacobians for use in intaod
!
! attributes:
!   language: f90
!   machine:  ibm RS/6000 SP
!
!$$$
!--------
  use kinds, only: r_kind,i_kind
  use mpimod, only: mype
  use radinfo, only: ifactq
  use radinfo, only: radjacindxs,nsigradjac
  use radinfo, only: nst_gsi,nst_tzr,nstinfo,fac_dtl,fac_tsl
  use guess_grids, only: ges_u,ges_v,ges_tsen,ges_q,ges_oz,&
      ges_ps,ges_prsl,ges_prsi,tropprs,dsfct,add_rtm_layers, &
      hrdifsig,nfldsig,hrdifsfc,nfldsfc,ntguessfc,ges_tv,isli2,sno2
  use ncepgfs_ghg, only: co2vmr_def
  use gsi_bundlemod, only: gsi_bundlegetpointer
  use gsi_chemguess_mod, only: gsi_chemguess_bundle   ! for now, a common block
  use gsi_chemguess_mod, only: gsi_chemguess_get
  use gsi_metguess_mod,  only: gsi_metguess_bundle   ! for now, a common block
  use gsi_metguess_mod,  only: gsi_metguess_get
  use gridmod, only: istart,jstart,nlon,nlat,lon1,regional
  use constants, only: zero,one,one_tenth,fv,r0_05,r10,r100,r1000,constoz,grav,rad2deg,deg2rad, &
      sqrt_tiny_r_kind,constoz, rd, rd_over_g, two, three, four,five,t0c

  use set_crtm_aerosolmod, only: set_crtm_aerosol
  use set_crtm_cloudmod, only: set_crtm_cloud
  use crtm_module, only: crtm_atmosphere_type,crtm_surface_type
  use crtm_parameters, only: limit_exp
  use obsmod, only: iadate
  use aeroinfo, only: nsigaerojac
  implicit none

! Declare passed variables
  real(r_kind)                          ,intent(in   ) :: obstime
  integer(i_kind)                       ,intent(in   ) :: nchanl,nreal
  integer(i_kind),dimension(nchanl)     ,intent(in   ) :: ich
  real(r_kind)                          ,intent(  out) :: trop5,tzbgr
  real(r_kind),dimension(nsig)          ,intent(  out) :: h,q,prsl
  real(r_kind),dimension(nsig+1)        ,intent(  out) :: prsi
  real(r_kind)                          ,intent(  out) :: sfc_speed,dtsavg
  real(r_kind),dimension(nchanl+nreal)  ,intent(in   ) :: data_s
  real(r_kind),dimension(nchanl)        ,intent(  out) :: tsim,emissivity,ts,emissivity_k
  character(10)                         ,intent(in   ) :: obstype
  integer(i_kind)                       ,intent(  out) :: error_status
  real(r_kind),dimension(nsig,nchanl)   ,intent(  out) :: temp,ptau5,wmix
  real(r_kind),dimension(nsigradjac,nchanl),intent(out):: jacobian
  real(r_kind)                          ,intent(  out) :: clw_guess
  real(r_kind),dimension(nsigaerojac,nchanl),intent(out),optional :: jacobian_aero
  real(r_kind),dimension(nsig,nchanl)   ,intent(  out)  ,optional :: layer_od

! Declare local parameters
  real(r_kind),parameter:: minsnow=one_tenth
  real(r_kind),parameter:: qsmall  = 1.e-6_r_kind
  real(r_kind),parameter:: ozsmall = 1.e-10_r_kind
  real(r_kind),parameter:: small_wind = 1.e-3_r_kind

! Declare local variables  
  integer(i_kind):: ier,ii,igfsco2,kk,kk2,i,itype,leap_day,day_of_year
  integer(i_kind):: j,k,m1,ix,ix1,ixp,iy,iy1,iyp,m
  integer(i_kind):: itsig,itsigp,itsfc,itsfcp
  integer(i_kind):: istyp00,istyp01,istyp10,istyp11
  integer(i_kind),dimension(8)::obs_time,anal_time
  integer(i_kind),dimension(msig) :: klevel

  real(r_kind):: w00,w01,w10,w11,kgkg_kgm2,f10,panglr,dx,dy
  real(r_kind):: delx,dely,delx1,dely1,dtsig,dtsigp,dtsfc,dtsfcp
  real(r_kind):: sst00,sst01,sst10,sst11,total_od,term,uu5,vv5, ps
  real(r_kind):: sno00,sno01,sno10,sno11,secant_term
  real(r_kind),dimension(0:3):: wgtavg
  real(r_kind),dimension(nsig,nchanl):: omix
  real(r_kind),dimension(nsig,nchanl,n_clouds):: cwj
  real(r_kind),dimension(nsig,nchanl,n_aerosols_jac):: jaero
  real(r_kind),dimension(nchanl) :: uwind_k,vwind_k
  real(r_kind),dimension(msig+1) :: prsi_rtm
  real(r_kind),dimension(msig)  :: prsl_rtm
  real(r_kind),dimension(msig)  :: auxq,auxdp
  real(r_kind),allocatable,dimension(:)::auxt,auxp
  real(r_kind),dimension(nsig)  :: poz,co2
  real(r_kind),dimension(nsig)  :: rh,qs,qclr
  real(r_kind),dimension(5)     :: tmp_time
  real(r_kind),dimension(0:3)   :: dtskin
  real(r_kind),dimension(nsig)  :: c2,c3,c4,c5
  real(r_kind),dimension(nsig)  :: dz, cw, tem2d
  real(r_kind) :: tref,dtw,dtc,tz_tr
  real(r_kind) tv, tem4, cf
  real(r_kind),dimension(nsig) :: ugkg_kgm2
  real(r_kind),pointer,dimension(:,:,:)::cfges_itsig =>NULL()
  real(r_kind),pointer,dimension(:,:,:)::cfges_itsigp=>NULL()
  real(r_kind),pointer,dimension(:,:,:)::co2ges_itsig =>NULL()
  real(r_kind),pointer,dimension(:,:,:)::co2ges_itsigp=>NULL()
  real(r_kind),pointer,dimension(:,:,:)::aeroges_itsig =>NULL()
  real(r_kind),pointer,dimension(:,:,:)::aeroges_itsigp=>NULL()
  real(r_kind),pointer,dimension(:,:,:)::cloudges_itsig =>NULL()
  real(r_kind),pointer,dimension(:,:,:)::cloudges_itsigp=>NULL()

  logical :: sea,icmask

  integer(i_kind),parameter,dimension(12):: mday=(/0,31,59,90,&
       120,151,181,212,243,273,304,334/)


  m1=mype+1

  dx  = data_s(ilat)                 ! grid relative latitude
  dy  = data_s(ilon)                 ! grid relative longitude

! Set spatial interpolation indices and weights
  ix1=dx
  ix1=max(1,min(ix1,nlat))
  delx=dx-ix1
  delx=max(zero,min(delx,one))
  ix=ix1-istart(m1)+2
  ixp=ix+1
  if(ix1==nlat) then
     ixp=ix
  end if
  delx1=one-delx

  iy1=dy
  dely=dy-iy1
  iy=iy1-jstart(m1)+2
  if(iy<1) then
     iy1=iy1+nlon
     iy=iy1-jstart(m1)+2
  end if
  if(iy>lon1+1) then
     iy1=iy1-nlon
     iy=iy1-jstart(m1)+2
  end if
  iyp=iy+1
  dely1=one-dely

  w00=delx1*dely1; w10=delx*dely1; w01=delx1*dely; w11=delx*dely



! Get time interpolation factors for sigma files
  if(obstime > hrdifsig(1) .and. obstime < hrdifsig(nfldsig))then
     do j=1,nfldsig-1
        if(obstime > hrdifsig(j) .and. obstime <= hrdifsig(j+1))then
           itsig=j
           itsigp=j+1
           dtsig=((hrdifsig(j+1)-obstime)/(hrdifsig(j+1)-hrdifsig(j)))
        end if
     end do
  else if(obstime <=hrdifsig(1))then
     itsig=1
     itsigp=1
     dtsig=one
  else
     itsig=nfldsig
     itsigp=nfldsig
     dtsig=one
  end if
  dtsigp=one-dtsig

! Get time interpolation factors for surface files
  if(obstime > hrdifsfc(1) .and. obstime < hrdifsfc(nfldsfc))then
     do j=1,nfldsfc-1
        if(obstime > hrdifsfc(j) .and. obstime <= hrdifsfc(j+1))then
           itsfc=j
           itsfcp=j+1
           dtsfc=((hrdifsfc(j+1)-obstime)/(hrdifsfc(j+1)-hrdifsfc(j)))
        end if
     end do
  else if(obstime <=hrdifsfc(1))then
     itsfc=1
     itsfcp=1
     dtsfc=one
  else
     itsfc=nfldsfc
     itsfcp=nfldsfc
     dtsfc=one
  end if
  dtsfcp=one-dtsfc
  jacobian=zero
  jacobian_aero=zero

  if (lcf4crtm) then
    call gsi_bundlegetpointer(gsi_metguess_bundle(itsig ),'cf',cfges_itsig ,ier)
    call gsi_bundlegetpointer(gsi_metguess_bundle(itsigp),'cf',cfges_itsigp,ier)
  endif

!$omp parallel sections private(k,i)

! Space-time interpolation of temperature (h) and q fields from sigma files
!$omp section 
  do k=1,nsig
     h(k)  =(ges_tsen(ix ,iy ,k,itsig )*w00+ &
             ges_tsen(ixp,iy ,k,itsig )*w10+ &
             ges_tsen(ix ,iyp,k,itsig )*w01+ &
             ges_tsen(ixp,iyp,k,itsig )*w11)*dtsig + &
            (ges_tsen(ix ,iy ,k,itsigp)*w00+ &
             ges_tsen(ixp,iy ,k,itsigp)*w10+ &
             ges_tsen(ix ,iyp,k,itsigp)*w01+ &
             ges_tsen(ixp,iyp,k,itsigp)*w11)*dtsigp
     q(k)  =(ges_q(ix ,iy ,k,itsig )*w00+ &
             ges_q(ixp,iy ,k,itsig )*w10+ &
             ges_q(ix ,iyp,k,itsig )*w01+ &
             ges_q(ixp,iyp,k,itsig )*w11)*dtsig + &
            (ges_q(ix ,iy ,k,itsigp)*w00+ &
             ges_q(ixp,iy ,k,itsigp)*w10+ &
             ges_q(ix ,iyp,k,itsigp)*w01+ &
             ges_q(ixp,iyp,k,itsigp)*w11)*dtsigp
     if (lcf4crtm) then
        cf    =(cfges_itsig (ix ,iy ,k)*w00+ &
                cfges_itsig (ixp,iy ,k)*w10+ &
                cfges_itsig (ix ,iyp,k)*w01+ &
                cfges_itsig (ixp,iyp,k)*w11)*dtsig + &
               (cfges_itsigp(ix ,iy ,k)*w00+ &
                cfges_itsigp(ixp,iy ,k)*w10+ &
                cfges_itsigp(ix ,iyp,k)*w01+ &
                cfges_itsigp(ixp,iyp,k)*w11)*dtsigp
        qs(k) =(gesqsat(ix ,iy ,k,itsig )*w00+ &
                gesqsat(ixp,iy ,k,itsig )*w10+ &
                gesqsat(ix ,iyp,k,itsig )*w01+ &
                gesqsat(ixp,iyp,k,itsig )*w11)*dtsig + &
               (gesqsat(ix ,iy ,k,itsigp)*w00+ &
                gesqsat(ixp,iy ,k,itsigp)*w10+ &
                gesqsat(ix ,iyp,k,itsigp)*w01+ &
                gesqsat(ixp,iyp,k,itsigp)*w11)*dtsigp

        if (cf<0.01_r_kind) then
           qclr(k) = q(k)
        else 
           qclr(k) = (q(k) - cf*qs(k))/(one-cf)
           if (qclr(k)<zero) then
              qclr(k)=max(qsmall,qclr(k))
           endif
        endif 
     endif

!  Ensure q is greater than or equal to qsmall

     q(k)=max(qsmall,q(k))

! Create constants for later

     if (lcf4crtm) then
        qclr(k)=max(qsmall,qclr(k))
        c2(k)=one/(one+fv*qclr(k))
        c3(k)=one/(one-qclr(k))
     else
        c2(k)=one/(one+fv*q(k))
        c3(k)=one/(one-q(k))
     endif
     c4(k)=fv*h(k)*c2(k)
     c5(k)=r1000*c3(k)*c3(k)
  end do

!$omp section

! Load geometry structure

! skip loading geometry structure if obstype is modis_aod
! iscan_ang,ilzen_ang,ilazi_ang are not available in the modis aod bufr file
! also, geometryinfo is not needed in crtm aod calculation
  if ( trim(obstype) /= 'modis_aod' ) then
     panglr = data_s(iscan_ang)
     if(obstype == 'goes_img' .or. obstype == 'seviri')panglr = zero
     geometryinfo(1)%sensor_zenith_angle = data_s(ilzen_ang)*rad2deg  ! local zenith angle
     geometryinfo(1)%source_zenith_angle = data_s(iszen_ang)          ! solar zenith angle
     geometryinfo(1)%sensor_azimuth_angle = data_s(ilazi_ang)         ! local zenith angle
     geometryinfo(1)%source_azimuth_angle = data_s(isazi_ang)         ! solar zenith angle
     geometryinfo(1)%sensor_scan_angle   = panglr*rad2deg             ! scan angle
     geometryinfo(1)%ifov                = nint(data_s(iscan_pos))    ! field of view position

!  For some microwave instruments the solar and sensor azimuth angles can be
!  missing  (given a value of 10^11).  Set these to zero to get past CRTM QC.

     if (geometryinfo(1)%source_azimuth_angle > 360.0_r_kind .OR. &
         geometryinfo(1)%source_azimuth_angle < zero ) &
         geometryinfo(1)%source_azimuth_angle = zero
     if (geometryinfo(1)%sensor_azimuth_angle > 360.0_r_kind .OR. &
         geometryinfo(1)%sensor_azimuth_angle < zero ) &
         geometryinfo(1)%sensor_azimuth_angle = zero

  endif ! end of loading geometry structure

!       Special block for SSU cell pressure leakage correction.   Need to compute
!       observation time and load into Time component of geometryinfo structure.
!       geometryinfo%time is only defined in CFSRR CRTM.
  if (obstype == 'ssu') then

!    Compute absolute observation time

     anal_time=0
     obs_time=0
     tmp_time=zero
     tmp_time(2)=obstime
     anal_time(1)=iadate(1)
     anal_time(2)=iadate(2)
     anal_time(3)=iadate(3)
     anal_time(5)=iadate(4)

!external-subroutine w3movdat()

     call w3movdat(tmp_time,anal_time,obs_time)

!    Compute decimal year, for example 1/10/1983
!    d_year = 1983.0 + 10.0/365.0

     leap_day = 0
     if( mod(obs_time(1),4)==0 ) then
        if( (mod(obs_time(1),100)/=0).or.(mod(obs_time(1),400)==0) ) leap_day = 1
     endif
     day_of_year = mday(obs_time(2)) + obs_time(3)
     if(obs_time(2) > 2) day_of_year = day_of_year + leap_day

!       WARNING:  Current /nwprod/lib/sorc/crtm_gfs does NOT include Time
!       as a component of the geometryinfo structure.   If SSU data is to
!       be assimilated with the cell pressure correction applied, one must
!       uncomment the line below and recompile the GSI with the CFSRR CRTM.
!       geometryinfo(1)%Time = float(obs_time(1)) + float(day_of_year)/(365.0_r_kind+leap_day)

     write(6,*)'CALL_CRTM:  ***WARNING*** SSU cell pressure correction NOT applied'
  endif

  igfsco2=0
  if(ico2>0) then
     call gsi_chemguess_get ( 'i4crtm::co2', igfsco2, ier )
     if(igfsco2>0)then
        if(size(gsi_chemguess_bundle)==1) then
           call gsi_bundlegetpointer(gsi_chemguess_bundle(1),'co2',co2ges_itsig ,ier)
        else
           call gsi_bundlegetpointer(gsi_chemguess_bundle(itsig ),'co2',co2ges_itsig ,ier)
           call gsi_bundlegetpointer(gsi_chemguess_bundle(itsigp),'co2',co2ges_itsigp,ier)
        endif
     endif
  endif

!$omp section 
! Space-time interpolation of ozone(poz), co2 and aerosol fields from sigma files
  do k=1,nsig
     poz(k)=((ges_oz(ix ,iy ,k,itsig )*w00+ &
              ges_oz(ixp,iy ,k,itsig )*w10+ &
              ges_oz(ix ,iyp,k,itsig )*w01+ &
              ges_oz(ixp,iyp,k,itsig )*w11)*dtsig + &
             (ges_oz(ix ,iy ,k,itsigp)*w00+ &
              ges_oz(ixp,iy ,k,itsigp)*w10+ &
              ges_oz(ix ,iyp,k,itsigp)*w01+ &
              ges_oz(ixp,iyp,k,itsigp)*w11)*dtsigp)*constoz

!    Ensure ozone is greater than ozsmall

     poz(k)=max(ozsmall,poz(k))

!    Get information for how to use CO2 and interpolate CO2

     co2(k) = co2vmr_def
     if(ico2>0) then
        if(igfsco2>0)then
           if(size(gsi_chemguess_bundle)==1) then
              co2(k) =(co2ges_itsig(ix ,iy ,k)*w00+ &
                       co2ges_itsig(ixp,iy ,k)*w10+ &
                       co2ges_itsig(ix ,iyp,k)*w01+ &
                       co2ges_itsig(ixp,iyp,k)*w11)
           else
              co2(k) =(co2ges_itsig (ix ,iy ,k)*w00+ &
                       co2ges_itsig (ixp,iy ,k)*w10+ &
                       co2ges_itsig (ix ,iyp,k)*w01+ &
                       co2ges_itsig (ixp,iyp,k)*w11)*dtsig + &
                      (co2ges_itsigp(ix ,iy ,k)*w00+ &
                       co2ges_itsigp(ixp,iy ,k)*w10+ &
                       co2ges_itsigp(ix ,iyp,k)*w01+ &
                       co2ges_itsigp(ixp,iyp,k)*w11)*dtsigp
           endif
        endif
     endif

!  Interpolate aerosols

     if(n_aerosols>0)then
        if(size(gsi_chemguess_bundle)==1) then
           do ii=1,n_aerosols
              call gsi_bundlegetpointer(gsi_chemguess_bundle(1),aero_names(ii),aeroges_itsig ,ier) ! _RT: not efficient
              aero(k,ii) =(aeroges_itsig(ix ,iy ,k)*w00+ &
                           aeroges_itsig(ixp,iy ,k)*w10+ &
                           aeroges_itsig(ix ,iyp,k)*w01+ &
                           aeroges_itsig(ixp,iyp,k)*w11)
           enddo
        else
           do ii=1,n_aerosols
              call gsi_bundlegetpointer(gsi_chemguess_bundle(itsig ),aero_names(ii),aeroges_itsig ,ier) ! _RT: not efficient
              call gsi_bundlegetpointer(gsi_chemguess_bundle(itsigp),aero_names(ii),aeroges_itsigp,ier) ! _RT: not efficient
              aero(k,ii) =(aeroges_itsig (ix ,iy ,k)*w00+ &
                           aeroges_itsig (ixp,iy ,k)*w10+ &
                           aeroges_itsig (ix ,iyp,k)*w01+ &
                           aeroges_itsig (ixp,iyp,k)*w11)*dtsig + &
                          (aeroges_itsigp(ix ,iy ,k)*w00+ &
                           aeroges_itsigp(ixp,iy ,k)*w10+ &
                           aeroges_itsigp(ix ,iyp,k)*w01+ &
                           aeroges_itsigp(ixp,iyp,k)*w11)*dtsigp
           enddo
        endif
        if(.not.lcf4crtm) then ! otherwise already calculated
           qs(k) =(gesqsat(ix ,iy ,k,itsig )*w00+ &
                   gesqsat(ixp,iy ,k,itsig )*w10+ &
                   gesqsat(ix ,iyp,k,itsig )*w01+ &
                   gesqsat(ixp,iyp,k,itsig )*w11)*dtsig + &
                  (gesqsat(ix ,iy ,k,itsigp)*w00+ &
                   gesqsat(ixp,iy ,k,itsigp)*w10+ &
                   gesqsat(ix ,iyp,k,itsigp)*w01+ &
                   gesqsat(ixp,iyp,k,itsigp)*w11)*dtsigp
        endif
        rh(k) = q(k)/qs(k)
     endif


  end do

!$omp section 

! Find tropopause height at observation

  trop5= one_tenth*(tropprs(ix,iy )*w00+tropprs(ixp,iy )*w10+ &
                    tropprs(ix,iyp)*w01+tropprs(ixp,iyp)*w11)

! Interpolate layer pressure to observation point

  do k=1,nsig
     prsl(k)=(ges_prsl(ix ,iy ,k,itsig )*w00+ &
              ges_prsl(ixp,iy ,k,itsig )*w10+ &
              ges_prsl(ix ,iyp,k,itsig )*w01+ &
              ges_prsl(ixp,iyp,k,itsig )*w11)*dtsig + &
             (ges_prsl(ix ,iy ,k,itsigp)*w00+ &
              ges_prsl(ixp,iy ,k,itsigp)*w10+ &
              ges_prsl(ix ,iyp,k,itsigp)*w01+ &
              ges_prsl(ixp,iyp,k,itsigp)*w11)*dtsigp
  end do

! Interpolate level pressure to observation point

  do k=1,nsig+1
     prsi(k)=(ges_prsi(ix ,iy ,k,itsig )*w00+ &
              ges_prsi(ixp,iy ,k,itsig )*w10+ &
              ges_prsi(ix ,iyp,k,itsig )*w01+ &
              ges_prsi(ixp,iyp,k,itsig )*w11)*dtsig + &
             (ges_prsi(ix ,iy ,k,itsigp)*w00+ &
              ges_prsi(ixp,iy ,k,itsigp)*w10+ &
              ges_prsi(ix ,iyp,k,itsigp)*w01+ &
              ges_prsi(ixp,iyp,k,itsigp)*w11)*dtsigp
  end do

! Quantities required for MW cloudy radiance calculations

  if (n_actual_clouds>0) then

     do k=1,nsig
        tv    =(ges_tv(ix ,iy ,k,itsig )*w00+ &
                ges_tv(ixp,iy ,k,itsig )*w10+ &
                ges_tv(ix ,iyp,k,itsig )*w01+ &
                ges_tv(ixp,iyp,k,itsig )*w11)*dtsig + &
               (ges_tv(ix ,iy ,k,itsigp)*w00+ &
                ges_tv(ixp,iy ,k,itsigp)*w10+ &
                ges_tv(ix ,iyp,k,itsigp)*w01+ &
                ges_tv(ixp,iyp,k,itsigp)*w11)*dtsigp
        do ii=1,n_actual_clouds
           call gsi_bundlegetpointer(gsi_metguess_bundle(itsig ),cloud_names(ii),cloudges_itsig ,ier) ! _RT: not efficient
           call gsi_bundlegetpointer(gsi_metguess_bundle(itsigp),cloud_names(ii),cloudges_itsigp,ier) ! _RT: not efficient
           cloud(k,ii) =(cloudges_itsig (ix ,iy ,k)*w00+ &     ! kg/kg
                         cloudges_itsig (ixp,iy ,k)*w10+ &
                         cloudges_itsig (ix ,iyp,k)*w01+ &
                         cloudges_itsig (ixp,iyp,k)*w11)*dtsig + &
                        (cloudges_itsigp(ix ,iy ,k)*w00+ &
                         cloudges_itsigp(ixp,iy ,k)*w10+ &
                         cloudges_itsigp(ix ,iyp,k)*w01+ &
                         cloudges_itsigp(ixp,iyp,k)*w11)*dtsigp
!          cloud(k,ii) =cloud(k,ii) * r1000*prsl(k)/(rd*tv)   ! [kg/kg] to [kg/m3]
           cloud(k,ii) =max(cloud(k,ii) * r1000 / rd,zero)  ! [kg/kg] to [kg/m3]
        end do

     end do
  endif ! <n_actual_clouds>

! Add additional crtm levels/layers to profile       

  call add_rtm_layers(prsi,prsl,prsi_rtm,prsl_rtm,klevel)

!$omp section 

!    Set surface type flag.  (Same logic as in subroutine deter_sfc)

  istyp00 = isli2(ix ,iy )
  istyp10 = isli2(ixp,iy )
  istyp01 = isli2(ix ,iyp)
  istyp11 = isli2(ixp,iyp)
  sno00= sno2(ix ,iy ,itsfc)*dtsfc+sno2(ix ,iy ,itsfcp)*dtsfcp
  sno01= sno2(ix ,iyp,itsfc)*dtsfc+sno2(ix ,iyp,itsfcp)*dtsfcp
  sno10= sno2(ixp,iy ,itsfc)*dtsfc+sno2(ixp,iy ,itsfcp)*dtsfcp
  sno11= sno2(ixp,iyp,itsfc)*dtsfc+sno2(ixp,iyp,itsfcp)*dtsfcp
  if(istyp00 >= 1 .and. sno00 > minsnow)istyp00 = 3
  if(istyp01 >= 1 .and. sno01 > minsnow)istyp01 = 3
  if(istyp10 >= 1 .and. sno10 > minsnow)istyp10 = 3
  if(istyp11 >= 1 .and. sno11 > minsnow)istyp11 = 3

!  Find delta Surface temperatures for all surface types

  sst00= dsfct(ix ,iy,ntguessfc) ; sst01= dsfct(ix ,iyp,ntguessfc)
  sst10= dsfct(ixp,iy,ntguessfc) ; sst11= dsfct(ixp,iyp,ntguessfc) 
  dtsavg=sst00*w00+sst10*w10+sst01*w01+sst11*w11

  dtskin(0:3)=zero
  wgtavg(0:3)=zero

  if(istyp00 == 1)then
     wgtavg(1) = wgtavg(1) + w00
     dtskin(1)=dtskin(1)+w00*sst00
  else if(istyp00 == 2)then
     wgtavg(2) = wgtavg(2) + w00
     dtskin(2)=dtskin(2)+w00*sst00
  else if(istyp00 == 3)then
     wgtavg(3) = wgtavg(3) + w00
     dtskin(3)=dtskin(3)+w00*sst00
  else
     wgtavg(0) = wgtavg(0) + w00
     dtskin(0)=dtskin(0)+w00*sst00
  end if

  if(istyp01 == 1)then
     wgtavg(1) = wgtavg(1) + w01
     dtskin(1)=dtskin(1)+w01*sst01
  else if(istyp01 == 2)then
     wgtavg(2) = wgtavg(2) + w01
     dtskin(2)=dtskin(2)+w01*sst01
  else if(istyp01 == 3)then
     wgtavg(3) = wgtavg(3) + w01
     dtskin(3)=dtskin(3)+w01*sst01
  else
     wgtavg(0) = wgtavg(0) + w01
     dtskin(0)=dtskin(0)+w01*sst01
  end if

  if(istyp10 == 1)then
     wgtavg(1) = wgtavg(1) + w10
     dtskin(1)=dtskin(1)+w10*sst10
  else if(istyp10 == 2)then
     wgtavg(2) = wgtavg(2) + w10
     dtskin(2)=dtskin(2)+w10*sst10
  else if(istyp10 == 3)then
     wgtavg(3) = wgtavg(3) + w10
     dtskin(3)=dtskin(3)+w10*sst10
  else
     wgtavg(0) = wgtavg(0) + w10
     dtskin(0)=dtskin(0)+w10*sst10
  end if

  if(istyp11 == 1)then
     wgtavg(1) = wgtavg(1) + w11
     dtskin(1)=dtskin(1)+w11*sst11
  else if(istyp11 == 2)then
     wgtavg(2) = wgtavg(2) + w11
     dtskin(2)=dtskin(2)+w11*sst11
  else if(istyp11 == 3)then
     wgtavg(3) = wgtavg(3) + w11
     dtskin(3)=dtskin(3)+w11*sst11
  else
     wgtavg(0) = wgtavg(0) + w11
     dtskin(0)=dtskin(0)+w11*sst11
  end if

  if(wgtavg(0) > zero)then
     dtskin(0) = dtskin(0)/wgtavg(0)
  else
     dtskin(0) = dtsavg
  end if
  if(wgtavg(1) > zero)then
     dtskin(1) = dtskin(1)/wgtavg(1)
  else
     dtskin(1) = dtsavg
  end if
  if(wgtavg(2) > zero)then
     dtskin(2) = dtskin(2)/wgtavg(2)
  else
     dtskin(2) = dtsavg
  end if
  if(wgtavg(3) > zero)then
     dtskin(3) = dtskin(3)/wgtavg(3)
  else
     dtskin(3) = dtsavg
  end if

!  Interpolate lowest level winds to observation location 

  uu5=(ges_u(ix,iy ,1,itsig )*w00+ges_u(ixp,iy ,1,itsig )*w10+ &
       ges_u(ix,iyp,1,itsig )*w01+ges_u(ixp,iyp,1,itsig )*w11)*dtsig + &
      (ges_u(ix,iy ,1,itsigp)*w00+ges_u(ixp,iy ,1,itsigp)*w10+ &
       ges_u(ix,iyp,1,itsigp)*w01+ges_u(ixp,iyp,1,itsigp)*w11)*dtsigp
  vv5=(ges_v(ix,iy ,1,itsig )*w00+ges_v(ixp,iy ,1,itsig )*w10+ &
       ges_v(ix,iyp,1,itsig )*w01+ges_v(ixp,iyp,1,itsig )*w11)*dtsig + &
      (ges_v(ix,iy ,1,itsigp)*w00+ges_v(ixp,iy ,1,itsigp)*w10+ &
       ges_v(ix,iyp,1,itsigp)*w01+ges_v(ixp,iyp,1,itsigp)*w11)*dtsigp
  if (n_clouds>0) then
      ps=(ges_ps(ix,iy ,itsig )*w00+ges_ps(ixp,iy ,itsig )*w10+ &
          ges_ps(ix,iyp,itsig )*w01+ges_ps(ixp,iyp,itsig )*w11)*dtsig + &
         (ges_ps(ix,iy ,itsigp)*w00+ges_ps(ixp,iy ,itsigp)*w10+ &
          ges_ps(ix,iyp,itsigp)*w01+ges_ps(ixp,iyp,itsigp)*w11)*dtsigp
  endif

! skip loading surface structure if obstype is modis_aod
  if (trim(obstype) /= 'modis_aod') then

! Factor for reducing lowest level winds to 10m (f10)

     f10=data_s(iff10)
     sfc_speed = f10*sqrt(uu5*uu5+vv5*vv5)

! Load surface structure

! **NOTE:  The model surface type --> CRTM surface type
!          mapping below is specific to the versions NCEP
!          GFS and NNM as of September 2005

     itype = int(data_s(ivty))
     if (regional) then
        itype = min(max(1,itype),nvege_type)
        surface(1)%land_type = nmm_to_crtm(itype)
     else
        itype = min(max(0,itype),13)
        surface(1)%land_type = gfs_to_crtm(itype)
     end if
 


     surface(1)%wind_speed           = sfc_speed
     surface(1)%wind_direction       = rad2deg*atan2(-uu5,-vv5)
     if ( surface(1)%wind_direction < zero ) surface(1)%wind_direction = &
        surface(1)%wind_direction + 180._r_kind

! CRTM will reject surface coverages if greater than one and it is possible for
! these values to be larger due to round off.

     surface(1)%water_coverage        = min(max(zero,data_s(ifrac_sea)),one)
     surface(1)%land_coverage         = min(max(zero,data_s(ifrac_lnd)),one)
     surface(1)%ice_coverage          = min(max(zero,data_s(ifrac_ice)),one)
     surface(1)%snow_coverage         = min(max(zero,data_s(ifrac_sno)),one)
     surface(1)%water_temperature     = max(data_s(its_sea)+dtskin(0),270._r_kind)
     if(nst_gsi>1 .and. surface(1)%water_coverage>zero) then
        surface(1)%water_temperature  = max(data_s(itref)+data_s(idtw)-data_s(idtc)+dtskin(0),271._r_kind)
     endif
     surface(1)%land_temperature      = data_s(its_lnd)+dtskin(1)
     surface(1)%ice_temperature       = min(data_s(its_ice)+dtskin(2),280._r_kind)
     surface(1)%snow_temperature      = min(data_s(its_sno)+dtskin(3),280._r_kind)
     surface(1)%soil_moisture_content = data_s(ism)
     surface(1)%vegetation_fraction   = data_s(ivfr)
     surface(1)%soil_temperature      = data_s(istp)
     surface(1)%snow_depth            = data_s(isn)

     sea = min(max(zero,data_s(ifrac_sea)),one)  >= 0.99_r_kind 
     icmask = sea .and. data_s(ilate)>-60.0_r_kind .and. n_clouds > 0

! assign tzbgr for Tz retrieval when necessary
     tzbgr = surface(1)%water_temperature

  endif ! end of loading surface structure

!$omp section 

! Load surface sensor data structure

  do i=1,nchanl

!  Pass CRTM array of tb for surface emissiviy calculations

     if (trim(obstype) /= 'modis_aod') &
        surface(1)%sensordata%tb(i) = data_s(nreal+i)

!  Set-up to return Tb jacobians.                                         

     rtsolution_k(i,1)%radiance = zero
     rtsolution_k(i,1)%brightness_temperature = one

     ! set up to return layer_optical_depth jacobians
     if (trim(obstype) == 'modis_aod') then
        rtsolution_k(i,1)%layer_optical_depth = one
     endif

  end do

!  Zero atmosphere jacobian structures

  call crtm_atmosphere_zero(atmosphere_k(:,:))
  call crtm_surface_zero(surface_k(:,:))

!$omp end parallel sections

  clw_guess = zero

  if (n_aerosols>0) then
     do k = 1, nsig
!       Convert mixing-ratio to concentration
        ugkg_kgm2(k)=1.0e-9_r_kind*(prsi(k)-prsi(k+1))*r1000/grav
        aero(k,:)=aero(k,:)*ugkg_kgm2(k)
     enddo
  endif

  do k = 1,msig

! Load profiles into extended RTM model layers

     kk = msig - k + 1
     atmosphere(1)%level_pressure(k) = r10*prsi_rtm(kk)
     atmosphere(1)%pressure(k)       = r10*prsl_rtm(kk)

     kk2 = klevel(kk)
     atmosphere(1)%temperature(k)    = h(kk2)
     if(lcf4crtm) then
        atmosphere(1)%absorber(k,1)  = r1000*qclr(kk2)*c3(kk2)
     else
        atmosphere(1)%absorber(k,1)  = r1000*q(kk2)*c3(kk2)
     endif
     atmosphere(1)%absorber(k,2)     = poz(kk2)
     atmosphere(1)%absorber(k,3)     = co2(kk2)

     if (n_aerosols>0) then
        aero_conc(k,:)=aero(kk2,:)
        auxrh(k)      =rh(kk2)
     endif

! Include cloud guess profiles in mw radiance computation
     if (lcw4crtm) then
        if (icmask) then
           if (kk > 1) then
              dz(kk2) = rd_over_g*log(prsi_rtm(kk-1)/prsi_rtm(kk))   !dz/tv
           else
              dz(kk2) = rd_over_g*log(prsi_rtm(kk)/prsi_rtm(kk+1))   !dz/tv
           endif

           ! Converting to cloud water content clw_test(kg/m3) to kg/m2
           cloud_cont(k,1) =  cloud(kk2,1)*prsl_rtm(kk)*dz(kk2)

           ! Dividing into liquid and ice clouds
           auxdp(k)=abs(prsi_rtm(kk+1)-prsi_rtm(kk))*r10
           auxq (k)=q(kk2)
           tem4= (t0c - atmosphere(1)%temperature(k))*r0_05
           tem4=max(zero,tem4)
           tem2d(kk2) = min(one, tem4)

           cloud_cont(k,2) =  cloud_cont(k,1)*tem2d(kk2)
           cloud_cont(k,1) =  cloud_cont(k,1)-cloud_cont(k,2)

           clw_guess = clw_guess +  cloud_cont(k,1)
        endif
     else if (n_clouds>0 .and. (.not.lcw4crtm)) then
        kgkg_kgm2=(atmosphere(1)%level_pressure(k)-atmosphere(1)%level_pressure(k-1))*r100/grav
        do ii=1,n_clouds
           cloud_cont(k,jcloud(ii))=cloud(kk2,ii)*kgkg_kgm2
        end do
     endif

! Add in a drop-off to absorber amount in the stratosphere to be in more
! agreement with ECMWF profiles.  This should be replaced when climatological fields
! are introduced.
     if (atmosphere(1)%level_pressure(k) < 200.0_r_kind) &
         atmosphere(1)%absorber(k,3) = atmosphere(1)%absorber(k,3) * &
        (0.977_r_kind + 0.000115_r_kind * atmosphere(1)%pressure(k))
  end do

! Set clouds for CRTM
  if(n_clouds>0) then
     allocate(auxt(size(atmosphere(1)%temperature)))
     allocate(auxp(size(atmosphere(1)%pressure)))
     auxt=atmosphere(1)%temperature
     auxp=atmosphere(1)%pressure
     call Set_CRTM_Cloud  ( msig, n_actual_clouds, cloud_names, icmask, n_clouds, cloud_cont, auxdp, & 
                            auxt, auxp, auxq, atmosphere(1)%cloud )
     deallocate(auxt,auxp)
  endif

! Set aerosols for CRTM
  if(n_aerosols>0) then
     call Set_CRTM_Aerosol ( msig, n_aerosols, n_aerosols_crtm, aero_names, aero_conc, auxrh, &
                             atmosphere(1)%aerosol )
  endif

! Call CRTM K Matrix model

  if ( trim(obstype) /= 'modis_aod' ) then
     error_status = crtm_k_matrix(atmosphere,surface,rtsolution_k,&
        geometryinfo,channelinfo(sensorindex:sensorindex),atmosphere_k,&
        surface_k,rtsolution,options=options)
  else
     !nesdis_crtm_aod error_status = crtm_aod_k(atmosphere,rtsolution_k,&
     !nesdis_crtm_aod   channelinfo(sensorindex:sensorindex),rtsolution,atmosphere_k)
  end if

! If the CRTM returns an error flag, do not assimilate any channels for this ob
! and set the QC flag to 10 (done in setuprad).

  if (error_status /=0) then
     write(6,*)'RAD_TRAN_K:  ***ERROR*** during crtm_k_matrix call ',&
        error_status
  end if

  if (trim(obstype) /= 'modis_aod' ) then
! Secant of satellite zenith angle

    secant_term = one/cos(data_s(ilzen_ang))

!   Zero jacobian and transmittance arrays
    temp   = zero
    wmix   = zero
    omix   = zero
    ptau5  = zero
    if(n_clouds > 0)cwj    = zero

!$omp parallel do  schedule(dynamic,1) private(i) &
!$omp private(total_od,k,kk,m,term,ii)

    do i=1,nchanl

!  Simulated brightness temperatures
       tsim(i)=rtsolution(i,1)%brightness_temperature

!  Estimated emissivity
       emissivity(i)   = rtsolution(i,1)%surface_emissivity

!  Emissivity sensitivities
       emissivity_k(i) = rtsolution_k(i,1)%surface_emissivity

!  Surface temperature sensitivity
       if(nst_gsi>1) then
          ts(i)   = surface_k(i,1)%water_temperature*data_s(itz_tr) + &
                    surface_k(i,1)%land_temperature + &
                    surface_k(i,1)%ice_temperature + &
                    surface_k(i,1)%snow_temperature
       else
          ts(i)   = surface_k(i,1)%water_temperature + &
                    surface_k(i,1)%land_temperature + &
                    surface_k(i,1)%ice_temperature + &
                    surface_k(i,1)%snow_temperature
       endif
 

       if (abs(ts(i))<sqrt_tiny_r_kind) ts(i) = sign(sqrt_tiny_r_kind,ts(i))

!  Surface wind sensitivities
       if (surface(1)%wind_speed>small_wind) then
          term = surface_k(i,1)%wind_speed * f10*f10 / surface(1)%wind_speed
          uwind_k(i) = term * uu5
          vwind_k(i) = term * vv5
       else
          uwind_k(i)    = zero
          vwind_k(i)    = zero
       endif


       total_od = zero

!   Accumulate values from extended into model layers
!   temp  - temperature sensitivity
!   wmix  - moisture sensitivity
!   omix  - ozone sensitivity
!   ptau5 - layer transmittance
       do k=1,msig
          kk = klevel(msig-k+1)
          temp(kk,i) = temp(kk,i) + atmosphere_k(i,1)%temperature(k)
          wmix(kk,i) = wmix(kk,i) + atmosphere_k(i,1)%absorber(k,1)
          if(icmask) then
             do ii=1,n_clouds
                cwj(kk,i,ii) = cwj(kk,i,ii) + atmosphere_k(i,1)%cloud(ii)%water_content(k)
             enddo
          endif
          omix(kk,i) = omix(kk,i) + atmosphere_k(i,1)%absorber(k,2)
          total_od   = total_od + rtsolution(i,1)%layer_optical_depth(k)
          ptau5(kk,i) = exp(-min(limit_exp,total_od*secant_term))
       end do

!  Load jacobian array
       m=ich(i)
       do k=1,nsig

!  Small sensitivities for temp
          if (abs(temp(k,i))<sqrt_tiny_r_kind) temp(k,i)=sign(sqrt_tiny_r_kind,temp(k,i))

!  Deflate moisture jacobian above the tropopause.
          if (itv>=0) then
             jacobian(itv+k,i)=temp(k,i)*c2(k)               ! virtual temperature sensitivity
          endif
          if (iqv>=0) then
              jacobian(iqv+k,i)=c5(k)*wmix(k,i)-c4(k)*temp(k,i)        ! moisture sensitivity
              if (prsi(k) < trop5) then
                 ifactq(m)=15
                 term = (prsi(k)-trop5)/(trop5-prsi(nsig))
                 jacobian(iqv+k,i) = exp(ifactq(m)*term)*jacobian(iqv+k,i)
              endif
          endif
          if (ioz>=0) then
!           if(.not. regional .or. use_gfs_ozone)then
              jacobian(ioz+k,i)=omix(k,i)*constoz       ! ozone sensitivity
!           end if
          endif
          if (n_clouds>0) then
             if(icmask) then
                if(lcw4crtm) then   ! handle special case of condensate split
                   jacobian(icw(1)+k,i) = prsl_rtm(k)*r1000*dz(k)*(one-tem2d(k))*cwj(k,i,1)/rd &
                                        + prsl_rtm(k)*r1000*dz(k)*     tem2d(k) *cwj(k,i,2)/rd 
                else                ! handle general case
                   do ii=1,n_clouds_jac
                      jacobian(icw(ii)+k,i) = prsl_rtm(k)*r1000*dz(k)*tem2d(k)*cwj(k,i,ii)/rd
                   end do
                endif
             else
                do ii=1,n_clouds_jac
                   jacobian(icw(ii)+k,i) = zero
                end do
             endif
          else
             do ii=1,n_clouds_jac
                jacobian(icw(ii)+k,i) = zero
             end do
          endif

       end do ! <nsig>

       if (ius>=0) then
           jacobian(ius+1,i)=uwind_k(i)         ! surface u wind sensitivity
       endif
       if (ivs>=0) then
           jacobian(ivs+1,i)=vwind_k(i)         ! surface v wind sensitivity
       endif
       if (isst>=0) then
           jacobian(isst+1,i)=ts(i)              ! surface skin temperature sensitivity
       endif
    end do
  endif ! obstype is not modis_aod

  if (trim(obstype) == 'modis_aod') then
     ! initialize intent(out) variables that are not available with modis_aod
     tzbgr        = zero
     sfc_speed    = zero
     tsim         = zero
     emissivity   = zero
     ts           = zero
     emissivity_k = zero
     ptau5        = zero
     temp         = zero
     wmix         = zero
     layer_od     = zero
     jaero        = zero
     do i=1,nchanl
        do k=1,msig
           kk = klevel(msig-k+1)
           layer_od(kk,i) = layer_od(kk,i) + rtsolution(i,1)%layer_optical_depth(k)
           do ii=1,n_aerosols_jac
              if ( n_aerosols_jac > n_aerosols_crtm .and. ii == indx_p25 ) then
                 jaero(kk,i,ii) = jaero(kk,i,ii) + &
                                  (0.5_r_kind*(0.78_r_kind*atmosphere_k(i,1)%aerosol(indx_dust1)%concentration(k) + &
                                               0.22_r_kind*atmosphere_k(i,1)%aerosol(indx_dust2)%concentration(k)) )
              else
                 jaero(kk,i,ii) = jaero(kk,i,ii) + atmosphere_k(i,1)%aerosol(ii)%concentration(k)
              endif
           enddo
        enddo
        do k=1,nsig
           do ii=1,n_aerosols_jac
              jacobian_aero(iaero_jac(ii)+k,i) = jaero(k,i,ii)**ugkg_kgm2(k)
           end do
        enddo
     enddo
  endif
  
  return
  end subroutine call_crtm

  end module crtm_interface
