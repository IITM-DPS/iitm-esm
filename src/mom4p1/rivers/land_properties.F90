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
module land_properties_mod

use mpp_domains_mod,    only: domain2d, mpp_get_compute_domain, mpp_get_global_domain
use time_manager_mod,   only: time_type, set_date, print_date, get_date,     &
                              operator(-), operator(>)
use mpp_io_mod,         only: mpp_open, mpp_RDONLY
use fms_mod,            only: error_mesg, file_exist, open_namelist_file,    &
                              check_nml_error, stdlog, write_version_number, &
                              mpp_pe, mpp_root_pe, close_file, read_data,    &
                              FATAL, NOTE, open_restart_file, set_domain,    &
                              field_size, stdout
use constants_mod,      only: tfreeze, pi
use horiz_interp_mod,   only: horiz_interp_type, horiz_interp_new, horiz_interp, &
                              horiz_interp_del
use diag_manager_mod,  only : register_static_field, send_data, get_base_time
use topography_mod,     only: get_topog_stdev
use numerics_mod, only: is_latlon 
implicit none
private

! ==== public interface =====================================================

public :: regrid_discrete_field
! ==== end public interface =================================================

contains

!#######################################################################


! <SUBROUTINE NAME="regrid_discrete_field">

!   <OVERVIEW>
!     Regrids integer index data to any output grid from a uniformly spaced
!     grid using a maximum-area voting scheme.
!   </OVERVIEW>

!   <DESCRIPTION>
!     Regrids integer index data to any output grid from a uniformly spaced
!     grid using a maximum-area voting scheme.
!   </DESCRIPTION>

!   <TEMPLATE>
!     call regrid_discrete_field (data_in, wb_in, sb_in, dlon_in, dlat_in, &
!     lon_out, lat_out, ntype, mask_out, data_out, mask_in)
!   </TEMPLATE>

!   <PUBLICROUTINE>
subroutine regrid_discrete_field (data_in, wb_in, sb_in, dlon_in, dlat_in, &
     lon_out, lat_out, ntype, &   
     mask_out, data_out, mask_in)

!-----------------------------------------------------------------------
!  input:
!  -----
!     data_in     input data; dimensioned by mdim x ndim
!                      stored from south to north
!     wb_in      longitude corresponding to western boundary of box i=1
!     sb_in      latitude corresponding to southern boundary of box j=1
!     dlon_in    x axis grid spacing in degrees of longitude
!     dlat_in    y axis grid spacing in degrees of latitude
!
!     lon_out   longitudes of output data at grid box corners
!                  dimensioned by size(data_out,1)+1 by size(data_out,2)+1
!     lat_out   latitudes of output data at grid box corners
!                  dimensioned by size(data_out,1)+1 by size(data_out,2)+1
!     ntype     number of land cover types specified
!     mask_out  output mask that specifies where the data are defined
!
!  output:
!  ------
!     data_out     output number of land cover type
!
!  optional
!  --------
!     mask_in   input mask;  =0.0 for data points that should not
!               be used or have no data; has the same size as data_in
!
!-----------------------------------------------------------------------
  integer, intent(in)           :: ntype
  integer, intent(in)           :: data_in(:,:)
  real,    intent(in)           :: sb_in,wb_in, dlat_in, dlon_in
  real,    intent(in)           :: lon_out(:,:), lat_out(:,:)
  logical, intent(in)           :: mask_out(:,:)
  integer, intent(out)          :: data_out(:,:)
  real,    intent(in), optional :: mask_in(:,:)
!   </PUBLICROUTINE>

  if (is_latlon(lon_out,lat_out)) then
     call regrid_discrete_field_latlon (data_in, wb_in, sb_in, dlon_in, dlat_in, &
                   lon_out(:,1), lat_out(1,:), ntype, mask_out, data_out, mask_in)
  else
     call error_mesg ('regrid_discrete_field',  &
       'Not a lat/lon grid', FATAL)
  endif

end subroutine regrid_discrete_field



! <SUBROUTINE NAME="regrid_discrete_field_latlon">
subroutine regrid_discrete_field_latlon (data_in, wb_in, sb_in, dlon_in, dlat_in, &
                                         lon_out, lat_out, ntype, &   
                                         mask_out, data_out, mask_in)
  integer, intent(in)           :: ntype
  integer, intent(in)           :: data_in(:,:)
  real,    intent(in)           :: sb_in,wb_in, dlat_in, dlon_in
  real,    intent(in)           :: lon_out(:), lat_out(:)
  logical, intent(in)           :: mask_out(:,:)
  integer, intent(out)          :: data_out(:,:)
  real,    intent(in), optional :: mask_in(:,:)

  ! --- local vars -----------------------------------------------------
  real,    dimension(size(data_in,2)) :: area_in
  real,    dimension(size(lat_out(:))) :: ph
  integer, dimension(size(data_out,1)) :: is,ie
  integer, dimension(size(data_out,2)) :: js,je,jsave
  real,    dimension(size(data_out,1)) :: fis,fie,facis,facie
  real,    dimension(size(data_out,2)) :: fjs,fje,facjs,facje,fsave

  integer  i,j,mdim,ndim,m360,nlon,nlat
  integer  ismin,iemax, iis,iie,jjs,jje, kk
  real     ratlat,ratlon,hpie,phs,phn, dsph
  real     ffacis,ffacie,ffacjs,ffacje
  logical  flip, enlarge

  integer, allocatable :: data(:,:)
  real,    allocatable :: area(:,:)

  hpie= pi/2.0
  mdim=size(data_in,1); ndim=size(data_in,2)
  m360=int(4.*hpie/dlon_in + 0.001)
  if (mdim < m360) call error_mesg ('regrid_discrete_field',  &
       'inner dimension for input data is too small.', FATAL)
  
  !   --- input (hires) grid resolution ---
  ratlat=1.0/dlat_in
  ratlon=1.0/dlon_in

  !   --- area of input (hires) grid boxes ---
  do j=1,ndim
     phs=sb_in + float(j-1)*dlat_in
     phn=sb_in + float(j)  *dlat_in
     phs=min(phs, hpie); phs=max(phs,-hpie)
     phn=min(phn, hpie); phn=max(phn,-hpie)
     dsph=sin(phn)-sin(phs)
     area_in(j) = dsph * dlon_in
  enddo

  !-----------------------------------------------------------------------

  nlon=size(data_out,1); nlat=size(data_out,2)

  !***********************************************************************

  !------ set up latitudinal indexing ------
  !------ make sure output grid goes south to north ------
  
  if (lat_out(1) < lat_out(nlat+1)) then
     ph(1:nlat+1) = lat_out(1:nlat+1)
     flip = .false.
  else
     ph(1:nlat+1) = lat_out(nlat+1:1:-1)
     flip = .true.
  endif

  fjs(1:nlat)=(ph(1:nlat  )-sb_in)*ratlat+1.0
  fje(1:nlat)=(ph(2:nlat+1)-sb_in)*ratlat+1.0

  js=fjs
  where (fjs < 0.) js=js-1
  where (js  < 1 ) js=1

  je=fje
  where (fje < 0.  ) je=je-1
  where (je  > ndim) je=ndim

  facjs=float(js+1)-fjs
  facje=fje-float(je)

  if (flip) then
     jsave=js; js(1:nlat)=jsave(nlat:1:-1)
     jsave=je; je(1:nlat)=jsave(nlat:1:-1)
     fsave=facjs; facjs(1:nlat)=fsave(nlat:1:-1)
     fsave=facje; facje(1:nlat)=fsave(nlat:1:-1)
  endif

  !------ set up longitudinal indexing ------

  fis(1:nlon)=(lon_out(1:nlon  )-wb_in)*ratlon+1.0
  fie(1:nlon)=(lon_out(2:nlon+1)-wb_in)*ratlon+1.0

  is=fis
  where (fis < 0.) is=is-1
  ie=fie
  where (fie < 0.) ie=ie-1

  facis=float(is+1)-fis
  facie=fie-float(ie)
  
  !----- allocate expanded data arrays ------
  
  ismin=min(minval(is),1)
  iemax=max(maxval(ie),mdim)

  allocate (data(ismin:iemax,1:ndim), area(ismin:iemax,1:ndim))

  data(1:mdim,1:ndim) = data_in(1:mdim,1:ndim)

  if (ismin < 1) then
     data(ismin:0, 1:ndim) = data_in(ismin+mdim:mdim, 1:ndim)
  endif
  if (iemax > mdim) then
     data(mdim+1:iemax, 1:ndim) =  data_in(1:iemax-mdim, 1:ndim)
  endif
  
  do j = 1,ndim
     area(:,j) = area_in(j)
  enddo
  
  if (present(mask_in)) then
     area(1:mdim,1:ndim) = area(1:mdim,1:ndim)*mask_in(1:mdim,1:ndim)
     if (ismin < 1)  &
          area(ismin:0, 1:ndim) = area(ismin+mdim:mdim, 1:ndim)
     if (iemax > mdim)  &
          area(mdim+1:iemax, 1:ndim) = area(1:iemax-mdim, 1:ndim)
  endif
  !-----------------------------------------------------------------------

  !     totarea=0.
  do j=1,nlat
     do i=1,nlon
        iis = is(i)
        iie = ie(i)
        jjs = js(j)
        jje = je(j)
        ffacis = facis(i)
        ffacie = facie(i)
        ffacjs = facjs(j)
        ffacje = facje(j)
        kk = 1
522     enlarge = .false.
        if (mask_out(i,j)) call typemax (data(iis:iie,jjs:jje), &
             area(iis:iie,jjs:jje), &
             ffacis,ffacie,ffacjs,ffacje,&
             ntype,data_out(i,j),enlarge)
        !         totarea(i,j)=sum(area(iis:iie,jjs:jje))
        
        if(is(i)-kk.le.1.and.ie(i)+kk.ge.mdim.and. &
             js(j)-kk.le.1.and.je(j)+kk.ge.ndim) goto 523
        
        if(enlarge) then
           if(is(i)-kk.ge.1) iis = is(i)-kk        
           if(ie(i)+kk.le.mdim) iie = ie(i)+kk
           if(js(j)-kk.ge.1) jjs = js(j)-kk
           if(je(j)+kk.le.ndim) jje = je(j)+kk
           ffacis = 1.
           ffacie = 1.
           ffacjs = 1.
           ffacje = 1.          
           kk=kk+1
           go to 522
        end if
523     continue
     enddo
  enddo

!      sumtype = 0.
!      do j=1,nlat
!      do i=1,nlon
!        do kk = 1, ntype
!          if(data_out(i,j).eq.kk) sumtype(kk)=sumtype(kk)+totarea(i,j)
!        end do  
!      enddo
!      enddo
!write(*,*)'ntype=',ntype
!do i = 1, ntype
!  write(*,*)'type,areatype=',i,sumtype(i)
!end do


  deallocate(data, area)

end subroutine regrid_discrete_field_latlon




! <SUBROUTINE NAME="typemax">

!   <OVERVIEW>
!     Calculation of total area of each land cover type within the territory
!     and the determination of the type occupying the biggest area within the
!     territory.
!   </OVERVIEW>

!   <DESCRIPTION>
!     Calculation of total area of each land cover type within the territory
!     and the determination of the type occupying the biggest area within the
!     territory.
!   </DESCRIPTION>

!   <TEMPLATE>
!     call typemax(data,area,facis,facie,facjs,facje,ntype,ntypemax,enlarge)
!   </TEMPLATE>

!   <PUBLICROUTINE>
subroutine typemax(data,area,facis,facie,facjs,facje,ntype,ntypemax,enlarge)

  integer, intent(in)    :: data(:,:)
  real,    intent(in)    :: facis,facie,facjs,facje
  real,    intent(in)    :: area(:,:)
  integer, intent(in)    :: ntype   
  integer, intent(out)   :: ntypemax ! number of land cover type to be assigned
                                     ! to the entire grid cell; 
  logical, intent(inout) :: enlarge  ! says if it's necessary to repeat the
                                     ! process for a larger area
!   </PUBLICROUTINE>

  ! --- local vars -----------------------------------------------------
  integer itype,id,jd,i,j  
  real, dimension(size(area,1),size(area,2)) :: wt
  real, dimension(ntype) :: sumarea     


  id=size(area,1); jd=size(area,2)
  
  wt = area
  wt( 1,:)=wt( 1,:)*facis
  wt(id,:)=wt(id,:)*facie
  wt(:, 1)=wt(:, 1)*facjs
  wt(:,jd)=wt(:,jd)*facje

! Calculation of total area of each land cover type within the territory:
  sumarea = 0.
  do i = 1, id
  do j = 1, jd
    do itype = 1, ntype
      if(int(data(i,j)).eq.itype) sumarea(itype)=sumarea(itype)+wt(i,j)
    end do
  end do
  end do

! Determination of the type occupying the biggest area within the territory:
  ntypemax = 0
    do itype = 1, ntype
      if(maxval(sumarea).eq.sumarea(itype).and.sumarea(itype).gt.0.) &
                ntypemax = itype
    end do

! Check if the land cover type is defined or not (ntypemax = 0  means  
! ocean or undefined type)
  if(ntypemax.eq.0) enlarge = .true.

end subroutine typemax

end module land_properties_mod
