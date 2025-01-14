!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!!                                                                   !!
!!                   GNU General Public License                      !!
!!                                                                   !!
!! This file is part of the Flexible Modeling System (FMS).          !!
!!                                                                   !!
!! FMS is free software; you can redistribute it and/or modify       !!
!! it and are expected to follow the terms of the GNU General Public !!
!! License as published by the Free Software Foundation.             !!
!!                                                                   !!
!! FMS is distributed in the hope that it will be useful,            !!
!! but WITHOUT ANY WARRANTY; without even the implied warranty of    !!
!! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the     !!
!! GNU General Public License for more details.                      !!
!!                                                                   !!
!! You should have received a copy of the GNU General Public License !!
!! along with FMS; if not, write to:                                 !!
!!          Free Software Foundation, Inc.                           !!
!!          59 Temple Place, Suite 330                               !!
!!          Boston, MA  02111-1307  USA                              !!
!! or see:                                                           !!
!!          http://www.gnu.org/licenses/gpl.txt                      !!
!!                                                                   !!
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
#include <fms_platform.h>

! ============================================================================
! an "umbrella" module for all land-related modules
! ============================================================================

module land_model_mod

! <CONTACT EMAIL="Chris.Milly@noaa.gov">
!   Christopher Milly
! </CONTACT> 

! <REVIEWER EMAIL="Elena.Shevliakova@noaa.gov">
!   Elena Shevliakova
! </REVIEWER>

! <REVIEWER EMAIL="Sergey.Malyshev@noaa.gov">
!   Sergey Malyshev
! </REVIEWER>

! <OVERVIEW>
!   This module contains calls to the sub-models to calculate quantities
!   on the fast and slow time scales and update the boundary conditions and
!   tiling structure where necessary.
! </OVERVIEW>

! <DESCRIPTION>
!   The sub-models (soil and vegetation) are first called in top-bottom order
!   to evaluate the derivatives. Then they are called in bottom-top order to
!   finish the implicit calculations. On the upward pass, they have a chance
!   to update boundary values returned to the atmosphere. These calls are done
!   on the fast time scale to calculate the fluxes.
!
!   On the slow time scale, the land is updated and the boundary conditions
!   may be updated. The land boundary data is updated on the fast time scale 
!   without updating the tiling structure. The land boundary data for the
!   atmosphere is updated on the slow time scale and changes the tiling
!   structure, if necessary, as well as the albedo, drag coefficient and such.
!
!   The diagnostic horizontal axes for the land grid is initialized. All 
!   sub-models use them instead of creating their own. Also, NetCDF library 
!   messages are printed out, including file names and line numbers.
! </DESCRIPTION>


  ! things from other modules which are used in the interface part
  ! of the land module
  use time_manager_mod, only: time_type

  use mpp_domains_mod,  only: domain1D, domain2d, mpp_get_layout, mpp_define_layout, &
                              mpp_define_domains, mpp_get_compute_domain,            &
                              CYCLIC_GLOBAL_DOMAIN, mpp_get_compute_domains,         &
                              mpp_get_domain_components, mpp_get_pelist,             &
                              mpp_define_mosaic

  use fms_mod,          only: write_version_number, error_mesg, FATAL, NOTE, &
                              mpp_pe, mpp_npes, mpp_root_pe, &
                              mpp_clock_id, mpp_clock_begin, mpp_clock_end, &
                              clock_flag_default, CLOCK_COMPONENT, file_exist, &
                              field_size, read_data, field_exist, &
                              set_domain, nullify_domain


  use rivers_mod,         only: rivers_type, rivers_init, rivers_end, &
                              update_rivers_slow, &
                              update_rivers_bnd_slow

  use land_types_mod,   only: land_data_type, allocate_boundary_data, &
                              atmos_land_boundary_type, deallocate_boundary_data 

  use numerics_mod,     only: is_latlon

  use constants_mod,   only:  radius, pi 

  use diag_manager_mod, only: diag_axis_init

implicit none
private


! ==== public interfaces =====================================================
public land_model_init          ! initialize the land model
public land_model_end           ! finish land model calculations
public update_land_model_slow   ! slow time-scale update of the land
public update_land_model_fast   ! slow time-scale update of the land
public Lnd_stock_pe
public land_model_restart

! ==== end of public interfaces ==============================================

! ==== public data type =====================================================
public land_type, land_data_type, atmos_land_boundary_type

! ==== generic interfaces ====================================================
! <INTERFACE NAME="land_model_init">
!   <OVERVIEW>
!     Initializes the state of the land model.
!   </OVERVIEW>
!   <DESCRIPTION>
!      Initializes the land state in three ways. 1) The grid description file may
!      be used as an input. The land grid boundaries and area of land are read from
!      a grid description file. 2) A logical land mask may be used to calculate the
!      area of the grid cells where the mask is true and calls init_land_with_area.
!      Naturally, in this case there are no partly covered land cells -- every cell
!      is either land or ocean. 3) The land state may be initialized from the land area
!      for each of the grid points.
!   </DESCRIPTION>
interface land_model_init
   module procedure init_land_with_xgrid
end interface
! </INTERFACE>


! <TYPE NAME="land_type">
!   <DESCRIPTION>
!     The type describing the state of the land model. It is private to this
!     module and is basically a remnant of the previous design. There is only one
!     variable of this type, called "theLand", which is used in the model to
!     hold the data.
!     Strictly speaking, this type is not necessary, but there is no harm in
!     having it and it is possible to image a situation where a single entity
!     describing the land-surface model state would be useful.
!   </DESCRIPTION>
type land_type

   private  ! it's an opaque type: all data members are private
   
!   <DATA NAME="domain" TYPE="domain2d" DIM="2">
!     Domain of calculations
!   </DATA>
!   <DATA NAME="is" TYPE="integer">
!     Domain bound
!   </DATA>
!   <DATA NAME="ie" TYPE="integer">
!     Domain bound
!   </DATA>
!   <DATA NAME="js" TYPE="integer">
!     Domain bound
!   </DATA>
!   <DATA NAME="je" TYPE="integer">
!     Domain bound
!   </DATA>
!   <DATA NAME="n_tiles" TYPE="integer">
!     Domain bound
!   </DATA>
   type(domain2d)         :: domain     ! domain of calculations
   integer :: is,ie,js,je,n_tiles       ! domain bounds, for convenience

!   <DATA NAME="rivers" TYPE="rivers_type">
!     rivers component data
!   </DATA>
   type(rivers_type)        :: rivers      

   ! the values below is just a quick fix to start running Land with original
   ! exchange grid, since it assumes something like that to be present. It also 
   ! assumes the number of tiles to be fixed.
   !   Of course, in general case there is no such thing as "latitude/longitude"
   ! boundaries of the cell, since cell boundaries do not have to be parallel
   ! to the lat/lon coordinate axes

!   <DATA NAME="blon" TYPE="real, pointer" DIM="2">
!     Longitude domain corners
!   </DATA>
!   <DATA NAME="blat" TYPE="real, pointer" DIM="2">
!     Latitude domain corners
!   </DATA>
!   <DATA NAME="mask" TYPE="logical, pointer" DIM="2">
!     Land mask, true where there is land
!   </DATA>
   real, pointer          :: blon(:,:) =>NULL()  ! longitude corners of our domain
   real, pointer          :: blat(:,:) =>NULL()  ! latitude corners of our domain 
   logical, pointer       :: mask(:,:) =>NULL()  ! land mask (true where ther is some land)

end type land_type

! ==== some names, for information only ======================================
logical                       :: module_is_initialized = .FALSE.
character(len=*),   parameter :: module_name = 'land_mod'
character(len=128), parameter :: version     = '$Id: land_model.F90,v 17.0 2009/07/21 03:03:34 fms Exp $'
character(len=128), parameter :: tagname     = '$Name: mom4p1_pubrel_dec2009_nnz $'


! ==== local module variables ================================================
integer                 :: n_tiles = 1  ! number of tiles
type(land_type),save    :: theLand  ! internal state of the model
integer :: landClock
integer :: isphum ! number of specific humidity in the tracer array, or NO_TRACER

contains ! -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-


! <SUBROUTINE NAME="init_land_with_xgrid" INTERFACE="land_model_init">
!   <OVERVIEW>
!     Initializes the land model
!   </OVERVIEW>
!   <DESCRIPTION>
!     The state of the land model is initialized using the grid description
!     file as an input. This routine reads land grid corners and area of
!     land from a grid description file.
!   </DESCRIPTION>
!   <PUBLICROUTINE INTERFACE="land_model_init">
subroutine init_land_with_xgrid &
     (atmos2land, bnd, time_init, time, dt_fast, dt_slow, atmos_domain)

  type(atmos_land_boundary_type), intent(inout) :: atmos2land ! land boundary data
  type(land_data_type), intent(inout) :: bnd ! land boundary data
  type(time_type), intent(in)    :: time_init ! initial time of simulation (?)
  type(time_type), intent(in)    :: time      ! current time
  type(time_type), intent(in)    :: dt_fast   ! fast time step
  type(time_type), intent(in)    :: dt_slow   ! slow time step
  type(domain2d),  intent(in), optional :: atmos_domain ! domain of computations
!   </PUBLICROUTINE>

  ! ---- local vars ----------------------------------------------------------
  real, allocatable :: glonb(:,:)   ! lon corners of global grid
  real, allocatable :: glatb(:,:)   ! lat corners of global grid
  real, allocatable :: glon(:,:)    ! lon centers of global grid
  real, allocatable :: glat(:,:)    ! lat centers of global grid
  real, allocatable :: gfrac    (:,:) ! fraction of land in cells
  real, allocatable :: gcellarea(:,:) ! area of land cells
  real, allocatable :: tmp_latb(:), tmp_lat(:)

  integer :: nlonb, nlatb  ! number of the cell bounds in lon and lat directions
  integer :: nlon,  nlat   ! number of cells in lon and lat directions
  integer :: siz(4)        ! used to store field size
  integer,save :: ntiles=1 ! number of tiles in land mosaic, should be 1 or 6.
  integer :: nfile_axl     ! number of atmosXland exchange grid file. Can be more than one.
  integer :: nxgrid        ! number of exchange grid cell.
  integer :: i, j, n, m, tile, ind, digit

  character(len=256) :: grid_file   = "INPUT/grid_spec.nc"

  ! [1] get land grid corners and area of land from the grid description file
  ! open grid description file
  
  if( field_exist(grid_file, 'AREA_LND') ) then
     call field_size( grid_file, 'AREA_LND', siz)
     nlon = siz(1)
     nlat = siz(2)
     nlonb = nlon + 1
     nlatb = nlat + 1
     ! allocate data for longitude and latitude bounds
     allocate( glonb(nlonb,nlatb), glatb(nlonb,nlatb), glon(nlon,nlat), glat(nlon,nlat),&
               gcellarea(nlon,nlat), gfrac(nlon,nlat), tmp_lat(nlat), tmp_latb(nlatb) )
     ! read coordinates of grid cell vertices
     call read_data(grid_file, "xbl", glonb(:,1), no_domain=.true.)
     call read_data(grid_file, "ybl", tmp_latb, no_domain=.true.)
     do j = 2, nlatb
        glonb(:,j) = glonb(:,1)
     enddo
     do i = 1, nlonb
        glatb(i,:) = tmp_latb(:)
     enddo

     ! read coordinates of grid cell centers
     call read_data(grid_file, "xtl", glon(:,1), no_domain=.true.)
     call read_data(grid_file, "ytl", tmp_lat(:), no_domain=.true.)
     do j = 2, nlat
        glon(:,j) = glon(:,1)
     enddo
     do i = 1, nlon
        glat(i,:) = tmp_lat(:)
     enddo

     ! read land area, land cell area and calculate the fractional land coverage 
     call read_data(grid_file, "AREA_LND_CELL", gcellarea, no_domain=.true.)
     call read_data(grid_file, "AREA_LND",      gfrac,     no_domain=.true.)
     ! calculate land fraction
     gfrac     = gfrac/gcellarea
     ! convert relative area to absolute value, m2
     gcellarea = gcellarea*4*pi*radius**2
  else
     call error_mesg('land_model_init','AREA_LND do not exist in file '//trim(grid_file),FATAL)
  end if

  ! [2] convert lon and lat coordinates from degrees to radian
  glonb = glonb*pi/180.0
  glatb = glatb*pi/180.0
  glon  = glon*pi/180.0
  glat  = glat*pi/180.0

  ! [3] initialize the land model using the global grid we just obtained
  call init_land_with_area &
       ( atmos2land, bnd, glonb, glatb, gcellarea, gfrac, time, dt_fast, dt_slow, &
       atmos_domain, glon=glon, glat=glat, numtiles=ntiles )

  ! [4] deallocate memory that we are not going to use any more
  deallocate ( glonb, glatb, glon, glat, gfrac, gcellarea )

!   <NOTE>
!     Theoretically, the grid description file can specify any regular
!     rectangular grid for land, not just lon/lat grid. Therefore the variables
!     "xbl" and "ybl" in NetCDF grid spec file are not necessarily lon and lat
!     boundaries of the grid.
!     However, at this time the module land_properties assumes that grid _is_
!     lon/lat and therefore the entire module also have to assume that the
!     land grid is lon/lat. lon/lat grid is also assumed for the diagnostics, 
!     but this is probably not so critical. 
!   </NOTE>
!Balaji: looks like this is the only public procedure under land_model_init
!        called from coupler_init
  landClock = mpp_clock_id( 'Land', flags=clock_flag_default, grain=CLOCK_COMPONENT )
!should also initialize subcomponent clocks for veg, hydro, etc. here
end subroutine init_land_with_xgrid



! <SUBROUTINE NAME="init_land_with_area" INTERFACE="land_model_init">
!   <OVERVIEW>
!     Initializes the land model
!   </OVERVIEW>
!   <DESCRIPTION>
!     Initializes the land state using land area for each of the grid points.
!   </DESCRIPTION>
!   <PUBLICROUTINE INTERFACE="land_model_init">
subroutine init_land_with_area &
     ( atmos2land, bnd, gblon, gblat, gcellarea, gfrac, time, dt_fast, dt_slow, domain, &
     glon, glat, numtiles )

  type(atmos_land_boundary_type), intent(inout) :: atmos2land ! land boundary data
  type(land_data_type), intent(inout) :: bnd        ! state to update
  real,              intent(in) :: gblon(:,:)! lon corners of the grid cells
  real,              intent(in) :: gblat(:,:)! lat corners of the grid cells
  real,              intent(in) :: gcellarea(:,:) ! full area of the grid cells
  real,              intent(in) :: gfrac(:,:)     ! fraction of land in the grid cell
  type(time_type),   intent(in) :: time    ! current time
  type(time_type),   intent(in) :: dt_fast ! fast time step
  type(time_type),   intent(in) :: dt_slow ! slow time step
  type(domain2d),    intent(in), optional :: domain  ! domain of computations
  real,              intent(in), optional :: glon(:,:), glat(:,:) ! centers
  integer,           intent(in), optional :: numtiles
                          ! of the grid cells

  ! ---- local vars ----------------------------------------------------------
  integer :: layout(2) ! layout of our domains
  integer :: nlon, nlat
  integer :: is,ie,js,je,k
  integer :: id_lon, id_lat  ! IDs of land diagnostic axes
  integer :: ntrace, ntprog, ntdiag, ntfamily ! numbers of tracers
  integer :: ntiles ! number of tiles for land mosaic

  module_is_initialized = .TRUE.

  ! write the version and tagname to the logfile
  call write_version_number(version, tagname)

  ! get the size of the global grid
  nlon = size(gfrac, 1)
  nlat = size(gfrac, 2)
  ! number of land mosaic tiles
  ntiles = 1
  if (present(numtiles)) ntiles = numtiles
  if (mod(mpp_npes(),ntiles) .NE. 0) call error_mesg('land_model_init', &
      'Number of processors must be a multiple of number of mosaic tiles', FATAL)
  ! get the processor layout information, either from upper-layer module
  ! decomposition, or define according to the grid size
  if(present(domain)) then
     call mpp_get_layout (domain, layout)
  else
     call mpp_define_layout &
          ((/1,nlon, 1,nlat/),mpp_npes()/ntiles,layout)
  endif

  ! create our computation domain according to obtained processor layout 
  if (ntiles .EQ. 1) then
     call mpp_define_domains ( &
          (/1,nlon, 1, nlat/),           &  ! global grid size
          layout,                        &  ! layout for our domains
          theLand%domain,                &  ! domain to define
          xflags = CYCLIC_GLOBAL_DOMAIN, name = 'LAND MODEL' )
  else
     call error_mesg('land_model_init',  &
        'number of mosaic tiles should be 1 ', FATAL)
  endif

  ! get the size of our computation domain
  call mpp_get_compute_domain ( theLand%domain, is,ie,js,je )

  theLand%is=is; theLand%ie=ie; theLand%js=js; theLand%je=je
  theLand%n_tiles=n_tiles

  ! NOTE: the piece of code from here to the end of the subroutine should
  ! probably be revised to accommodate tiling structure. The problem is that
  ! it is theoretically possible that the soil and vegetation have different
  ! tiling, or there may be an additional sub-model with yet different tiling. 
  ! It is case it is not quite clear what does the "land tile" mean -- it may 
  ! be the tile of the uppermost land sub-model (since this is what atmosphere 
  ! sees) or it may be decart product of all the sub-model tiling structures, 
  ! just to name two possibilities.

  ! allocate fractional area for rivers

  ! allocate storage for the boundary data 
  call allocate_boundary_data ( atmos2land, bnd, theLand%domain, n_tiles )

  ! set up boundary values that we know already
  bnd % domain = theLand % domain
  do k = 1, size(bnd%tile_size,3)
     where (gfrac(is:ie,js:je)>0)
        bnd % tile_size (:,:,k) = 1.0/n_tiles
        bnd % mask      (:,:,k) = .true.
     elsewhere
        bnd % tile_size (:,:,k) = 0.0
        bnd % mask      (:,:,k) = .false.
     endwhere
  enddo

  ! init grid variables: this is a quick fix since it is not yet
  ! clear how to initialize land properties with arbitrary grid
  allocate(theLand%blon(is:ie+1,js:je+1), theLand%blat(is:ie+1,js:je+1), theLand%mask(is:ie,js:je))
  theLand%blon(:,:)   = gblon(is:ie+1,js:je+1)
  theLand%blat(:,:)   = gblat(is:ie+1,js:je+1)
  theLand%mask(:,:)   = any( bnd % mask, DIM=3 )

  ! initialize land diagnostics -- create diagnostic axes to be used by all
  ! diagnostic routine in submodules
  call init_land_diag ( gblon, gblat, theLand%domain, id_lon, id_lat, &
       glon=glon, glat=glat )
  bnd%axes = (/id_lon, id_lat/)

  ! initialize all submodules
!  call soil_init ( theLand%soil, gblon, gblat, gcellarea, gfrac, &
!       time, dt_fast, dt_slow, theLand%domain, bnd % tile_size, bnd % mask, &
!       id_lon, id_lat )

  call rivers_init ( theLand%rivers, gblon, gblat, gcellarea, gfrac, time, dt_fast, dt_slow, theland%domain, &
     id_lon, id_lat )

!   <NOTE>
!     NOTE: we assume every sub-model has the same domain layout and is on
!     the same grid, so we do not need to do general-case flux exchange
!     between them.
!   </NOTE>

end subroutine init_land_with_area



! <SUBROUTINE NAME="land_model_end">

!   <DESCRIPTION>
!     Destructs the land model and its sub-models. Deallocates the arrays
!     and the boundary exchange data 
!   </DESCRIPTION>

subroutine land_model_end ( atmos2land, bnd )
  type(atmos_land_boundary_type), intent(inout) :: atmos2land
  type(land_data_type), intent(inout) :: bnd        ! state to update
  module_is_initialized = .FALSE.
  call rivers_end ( theLand%rivers )

  ! deallocate variables
  deallocate ( theLand%blon, theLand%blat, theLand%mask )

  ! deallocate boundary exchange data
  call deallocate_boundary_data ( atmos2land, bnd )
  
end subroutine land_model_end




! <SUBROUTINE NAME="update_land_model_slow">
!   <DESCRIPTION>
!     Updates land, and boundary conditions if
!     necessary, on the slow time scale. 
!   </DESCRIPTION>
subroutine update_land_model_slow ( atmos2land, bnd )
  type(atmos_land_boundary_type), intent(inout) :: atmos2land
  type(land_data_type), intent(inout) :: bnd        ! state to update

  call mpp_clock_begin(landClock)
  call set_domain (theLand%domain)
  call update_rivers_slow(theLand%rivers, atmos2land%runoff(:,:,1), atmos2land%drainage(:,:,1))
  call update_rivers_bnd_slow ( theLand%rivers, bnd )
  call nullify_domain()
  call mpp_clock_end(landClock)

end subroutine update_land_model_slow





! <SUBROUTINE NAME="init_land_diag">
!   <DESCRIPTION>
!     Initialize the horizontal axes for the land grid so that all
!     submodules use them, instead of creating their own.
!   </DESCRIPTION>
subroutine init_land_diag(glonb, glatb, domain, id_lon, id_lat, glon, glat)

  real, intent(in)           :: glonb(:,:), glatb(:,:) ! longitude and latitude corners of grid
                                                       ! cells, specified for the global grid
                                                       ! (not only domain)
  type(domain2d), intent(in) :: domain ! the domain of operations
  integer, intent(out)       :: id_lon, id_lat         ! IDs of respective diag. manager axes
  real, intent(in),optional  :: glon(:,:), glat(:,:)   ! coordinates of grid cell centers
!   </PUBLICROUTINE>

  ! ---- local vars ----------------------------------------------------------
  integer :: id_lonb, id_latb ! IDs for cell boundaries
  integer :: nlon, nlat       ! sizes of respective axes, just for convenience
  real    :: rad2deg          ! conversion factor radian -> degrees
  real    :: lon(size(glonb,1)-1), lat(size(glatb,2)-1)
  integer :: i, j

  rad2deg = 180./pi
  nlon = size(glonb,1)-1
  nlat = size(glatb,2)-1

  if (is_latlon(glonb,glatb)) then

 !----- lat/lon grid -----

     if(present(glon)) then
        lon = glon(:,1)
     else
        lon = (glonb(1:nlon,1)+glonb(2:nlon+1,1))/2
     endif
     if(present(glat)) then
        lat = glat(1,:)
     else
        lat = (glatb(1,1:nlat)+glatb(1,2:nlat+1))/2
     endif

     ! define longitude axes and its edges
     id_lonb = diag_axis_init ( &
          'lonb', glonb(:,1)*rad2deg, 'degrees_E', 'X', 'longitude edges', &
          set_name='land', domain2=domain )
     id_lon  = diag_axis_init (                                                &
          'lon', lon(:)*rad2deg, 'degrees_E', 'X',  &
          'longitude', set_name='land',  edges=id_lonb, domain2=domain )

     ! define latitude axes and its edges
     id_latb = diag_axis_init ( &
          'latb', glatb(1,:)*rad2deg, 'degrees_N', 'Y', 'latitude edges',  &
          set_name='land',  domain2=domain   )
     id_lat = diag_axis_init (                                                &
          'lat', lat(:)*rad2deg, 'degrees_N', 'Y', &
          'latitude', set_name='land', edges=id_latb, domain2=domain   )

!----- cubed sphere grid -----

  else
     do i = 1, nlon
       lon(i) = real(i)
     enddo
     do j = 1, nlat
       lat(j) = real(j)
     enddo

     id_lon = diag_axis_init ( 'grid_xt', lon, 'degrees_E', 'X', &
            'T-cell longitude', set_name='land',  domain2=domain )
     id_lat = diag_axis_init ( 'grid_yt', lat, 'degrees_N', 'Y', &
             'T-cell latitude', set_name='land',  domain2=domain )

  endif

end subroutine init_land_diag

subroutine Lnd_stock_pe(bnd,index,value)
type(land_data_type), intent(in) :: bnd
integer, intent(in) :: index
real,    intent(out) :: value

value = 0.0

end subroutine Lnd_stock_pe

subroutine update_land_model_fast ( atmos2land, bnd )
  type(atmos_land_boundary_type), intent(inout)    :: atmos2land
  type(land_data_type),  intent(inout) :: bnd ! state to update

  return

end subroutine update_land_model_fast

subroutine land_model_restart(timestamp)
  character(*), intent(in), optional :: timestamp ! timestamp to add to the file    name

end subroutine land_model_restart

end module land_model_mod
   
