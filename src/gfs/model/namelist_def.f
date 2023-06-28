      module namelist_def
      use machine
      implicit none
      save
      integer nszer,restart_interval(6),nslwr,nsout,nsswr,nsdfi,nscyc,
     &        igen,jo3,ngptc
     &,       lsm,ens_mem,ncw(2),num_reduce
      real(kind=kind_evod) fhswr,fhlwr,fhseg,fhmax,fhout,fhres,
     & fhzer,fhini,fhcyc,filta,crtrh(3),flgmin(2),ref_temp,ccwf,
     & ctei_rm,bkgd_vdif
      logical ldiag3d,ras,zhao_mic,sashal,newsas,crick_proof,ccnorm
      logical mom4ice,mstrat,trans_trac,climate
      logical lsfwd,lssav,lscca,lsswr,lslwr
      logical shuff_lats_a,shuff_lats_r,reshuff_lats_a,reshuff_lats_r
      logical hybrid,gen_coord_hybrid,zflxtvd				! hmhj
      logical run_enthalpy, out_virttemp                                ! hmhj
      logical adiab,explicit,pre_rad,random_xkt2,old_monin,cnvgwd       ! hmhj
      logical restart, gfsio_in, gfsio_out
      logical :: do_filter, is_first_time

      character*20 ens_nam
!
!     Radiation control parameters
!
      logical norad_precip
      integer isol, ico2, ialb, iems, iaer, iovr_sw, iovr_lw, ictm
!!!!! edit by Dr. Rashmi Kakatkar :
!! mnyear added for ghg update (i.e. update in radiation_gases.f code )
!! new option for solar constant frequency ( isolf ) is added
      integer mnyear, isolf
      integer isubc_sw, isubc_lw
      end module namelist_def
