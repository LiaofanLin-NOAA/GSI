!********************************************************
!* program: create_markers                              *
!* This program reads a control file with station info  *
!* and write out a list of google map markers           *
!* with the station name, lat/lon info                  *
!* Yangrong Ling, 06/2011                               *
!********************************************************

program create_markes_multilevel
 use strings
 implicit none

 integer, parameter :: MAX_CHAR_LENGTH=400 !maximum string length
 integer, parameter :: MAX_NUM_TOKENS=20 !maximum number of tokens in a line
 character(len=80) :: input_ctl_file, output_php
 character(len=25) :: png_file
 character(len=MAX_CHAR_LENGTH) :: line_buffer
 character(len=MAX_CHAR_LENGTH) :: tokens(MAX_NUM_TOKENS)
 character(len=8) :: station_id
 character(len=5) :: type
 real :: lat_temp, lon_temp, lat, lon
 character(len=5) :: lat_temp_c
 character(len=6) :: lon_temp_c
 character(len=4) :: qflag !quality flag for normal, bias, reject, and qreject

 integer :: num_stations, num_tokens, ios, argc, i

 argc=command_argument_count()
 if(argc<1) then
   print *, "Usage: create_markers_multilevel <input_ctl_file>"
   call exit(1)
 end if

 call get_command_argument(1, input_ctl_file)
 call parse (input_ctl_file, '_', tokens, num_tokens)
 type=tokens(1)

 !open the input sonde dictionary file
 open (unit=21, file=trim(input_ctl_file), status="old", iostat=ios)

 output_php = trim(type)//".php"

 !open the output php files
 open (unit=51, file=trim(output_php), status="new", iostat=ios)


 num_stations = 0

 95   Format("[", f7.2, ",", f8.2, " ,", "'", a4, "'", ",  '<rfont>", a8, "</rfont> <br>'")
! 95   Format("[", f7.2, ",", f8.2, ",  '<rfont>", a8, "</rfont> <br>'")
! 96   Format('  +', "'", '<a href="../pngs/', a25, '" target="_blank" >', "OBS</a> <br>'")  
! 97   Format('  +', "'", '<a href="../pngs/', a25, '" target="_blank" >', "OMG</a> <br>'")

 write(51, *)"sites = ["
 write(51, *)

 do
   read (21, '(A)', iostat=ios) line_buffer
   if (ios<0) exit !Negative ios means end-of-file

   call parse (line_buffer, ';', tokens, num_tokens)
   if(num_tokens .gt. 2) then
      num_stations = num_stations + 1
   
      station_id = tokens(1)
      lat_temp_c = tokens(2)
      lon_temp_c = tokens(3)
      qflag = tokens(4)

      call value(lat_temp_c, lat_temp, ios)
      call value(lon_temp_c, lon_temp, ios)

      lat = lat_temp
      if(lon_temp<180) then
         lon = lon_temp 
      else
         lon = lon_temp - 360
      end if


      png_file = trim(type)//'/'//trim(type)//'_'//trim(station_id)//'.png'

      write(51, fmt=95) lat, lon, qflag, station_id
      write(51, *) '  +',"'", '<a href="../', trim(png_file),'" target="_blank" >', "OBS/OMG</a> <br>'"
      write(51, *) "],"
      write(51, *)

   else
     cycle

   end if!num_tokens .ge. 2 

 end do

 write(51, *)"];"
 
 close (21)
 close (51)

 print *, "Total number of stations: ", num_stations

end program create_markes_multilevel