      module LinearOperators
      
         use lightkrylov, krylov_atol => atol
         use NekVectors
      
         implicit none
         include 'SIZE'
         include 'TOTAL'
         include 'ADJOINT'
      
         private
      
      !------------------------------------------
      !-----     EXPONENTIAL PROPAGATOR     -----
      !------------------------------------------
      
         type, extends(abstract_linop), public :: exponential_prop
            real :: t
         contains
            private
            procedure, pass(self), public :: matvec => direct_solver
            procedure, pass(self), public :: rmatvec => adjoint_solver
         end type exponential_prop
      
      !--------------------------------------
      !-----     RESOLVENT OPERATOR     -----
      !--------------------------------------
      
         type, extends(abstract_linop), public :: resolvent_op
            real :: t ! not omega here !
         contains
            private
            procedure, pass(self), public :: matvec => direct_map
            procedure, pass(self), public :: rmatvec => adjoint_map
         end type resolvent_op
      
      contains
      
         subroutine direct_solver(self, vec_in, vec_out)
      
            implicit none
            class(exponential_prop), intent(in) :: self
            class(abstract_vector), intent(in) :: vec_in
            class(abstract_vector), intent(out) :: vec_out
            logical, save :: orbit_alocated = .false.
      
            select type (vec_in)
            type is (real_nek_vector)
               select type (vec_out)
               type is (real_nek_vector)
      
                  if (findiff_order > 1) then
                     call setup_FD
                     call setupLinearSolver('DIRECT FD', orbit_alocated)
                     call nekstab_solver('DIRECT FD', orbit_alocated, vec_in, vec_out)
                  else
                     call setupLinearSolver('DIRECT   ', orbit_alocated)
                     call nekstab_solver('DIRECT   ', orbit_alocated, vec_in, vec_out)
                  end if
      
               end select
            end select
      
         contains
      
            subroutine setup_FD
               implicit none
               include 'TOTAL'
      
      ! For 2nd-order finite difference
               if (findiff_order == 2) then ! coefs and amps allocated with 4 elements
                  ampls = [1.0d0, -1.0d0, 0.0d0, 0.0d0]
                  coefs = [1.0d0, -1.0d0, 0.0d0, 0.0d0]/2.0d0
      ! For 4th-order finite difference
               else if (findiff_order == 4) then
                  ampls = [1.0d0, -1.0d0, 2.0d0, -2.0d0]
                  coefs = [8.0d0, -8.0d0, -1.0d0, 1.0d0]/12.0d0
               end if
      
            end subroutine setup_FD
      
         end subroutine direct_solver
      
         subroutine adjoint_solver(self, vec_in, vec_out)
      
            implicit none
            class(exponential_prop), intent(in) :: self
            class(abstract_vector), intent(in) :: vec_in
            class(abstract_vector), intent(out) :: vec_out
            logical, save :: orbit_alocated = .false.
      
            select type (vec_in)
            type is (real_nek_vector)
               select type (vec_out)
               type is (real_nek_vector)
      
                  call setupLinearSolver('ADJOINT  ', orbit_alocated)
                  call nekstab_solver('ADJOINT  ', orbit_alocated, vec_in, vec_out)
      
               end select
            end select
      
         end subroutine adjoint_solver
      
         subroutine setupLinearSolver(solver_type, orbit_alocated)
      
            implicit none
            include 'SIZE'
            include 'TOTAL'
            include 'ADJOINT'
      
            character(len=9), intent(in) :: solver_type
            logical, intent(inout) :: orbit_alocated
      
            ifpert = .true. ! turn on linearized solver (default)
            ifadj = .false. ! turn off adjoint solver (default)
            ifbase = .false. ! turn off nonlinear solver (default)
      
      ! Adjust settings based on solver_type
            if (solver_type == 'DIRECT FD') ifpert = .false. ! no need for linearized solver
            if (solver_type == 'ADJOINT  ') ifadj = .true. ! turn on adjoint solver
      
            if (isFloquetDirect .or. isFloquetAdjoint .or. isFloquetTransientGrowth .or.
     $   isNewtonPO .or. isNewtonPO_T) then
            ifbase = .true. ! turn on nonlinear solver for Floquet
      
      ! in the direct/adjoint mode the nonlinear solution is already stored
            if (solver_type == 'ADJOINT  ' .and. isFloquetTransientGrowth) orbit_alocated = .true.
      
      ! turn off nonlinear solver if criteria met
            if (ifstorebase .and. orbit_alocated) ifbase = .false.
      
            if (ifstorebase .and. ifbase .and. .not. orbit_alocated) then
      
               if (nid == 0) write (*, *) 'ALLOCATING ORBIT WITH NSTEPS:', nsteps
      
               allocate (uor(lv, nsteps), vor(lv, nsteps))
               if (if3d) then
                  allocate (wor(lv, nsteps))
               else
                  allocate (wor(1, 1))
               end if
               if (ifto .or. ldimt > 1) allocate (tor(lt, nsteps, ldimt))
      
               orbit_alocated = .true.
            end if
      
            end if
      
            if (nid == 0) then ! for debug purposes
               write (*, *) 'Setting up linear solver with solver_type=', solver_type
               write (*, *) 'ifbase, ifpert, ifadj=', ifbase, ifpert, ifadj
               write (*, *) 'orbit_alocated, ifstorebase=', orbit_alocated, ifstorebase
               write (*, *) 'endTime, dt, nsteps, fintim=', fintim, dt, nsteps
               write (*, *) 'isNewtonFP, isNewtonPO, isNewtonPO_T=', isNewtonFP, isNewtonPO, isNewtonPO_T
               write (*, *) 'isDirect, isFloquetDirect=', isDirect, isFloquetDirect
               write (*, *) 'isAdjoint, isFloquetAdjoint=', isAdjoint, isFloquetAdjoint
               write (*, *) 'isTransientGrowth, isFloquetTransientGrowth=', isTransientGrowth, isFloquetTransientGrowth
               write (*, *) 'isResolvent, isFloquetResolvent=', isResolvent, isFloquetResolvent
               write (*, *) '   '
            end if
      
            end subroutine setupLinearSolver
      
            subroutine nekstab_solver(solver_type, orbit_stored, in, out)
               use NekVectors
               implicit none
               include 'SIZE'
               include 'TOTAL'
               include 'ADJOINT'
      
               character(len=*), intent(in) :: solver_type
               logical, intent(inout) :: orbit_stored
               type(real_nek_vector), intent(in) :: in
               type(real_nek_vector), intent(out) :: out
      
               type(real_nek_vector) :: work, pert
               real :: epsilon0, work_norm
               integer :: i, m
               integer :: krylov_counter = 1
               integer, save :: matvec_counter = 0
      
               nt = nx1*ny1*nz1*nelt
            
      ! --> Setup the Nek parameters for the finite-differences approximation.
               if (solver_type == 'DIRECT FD') then
      
                  call nopcopy(work%vx, work%vy, work%vz, work%pr, work%t, ubase, vbase, wbase, pbase, tbase)
      
                  work_norm = work%dot(work)
                  work_norm = dsqrt(work_norm)
                  epsilon0 = epsilon_base*work_norm
                  ampls = ampls*epsilon0
      
                  if (nid == 0) then
                     write (*, *) 'epsilon_base, work_norm=', epsilon_base, work_norm
                     write (*, *) 'epsilon0=', epsilon0
                     write (*, *) 'ampls(:)=', ampls(:)
                     write (*, *) 'coefs(:)=', coefs(:)
                  end if
      
               else
      
      ! --> Pass the initial condition for the perturbation.
                  call nopcopy(vxp(:, 1), vyp(:, 1), vzp(:, 1), prp(:, 1), tp(:, :, 1), in%vx, in%vy, in%vz, in%pr, in%t)
      
               end if
      
               do i = 1, findiff_order
      
                  if (solver_type == 'DIRECT FD') then
      
      ! --> Scale the perturbation.
                     call nopcopy(pert%vx, pert%vy, pert%vz, pert%pr, pert%t, in%vx, in%vy, in%vz, in%pr, in%t)
                     call nopcmult(pert%vx, pert%vy, pert%vz, pert%pr, pert%t, ampls(i))
      
      ! --> Initial condition for the each evaluation.
                     call nopcopy(vx, vy, vz, pr, t, ubase, vbase, wbase, pbase, tbase)
                     call nopadd2(vx, vy, vz, pr, t, pert%vx, pert%vy, pert%vz, pert%pr, pert%t)
                     if (ifbf2d .and. if3d) call rzero(vz, nv)
      
                  end if
      
      ! --> Integrate in time.
                  time = 0.0d0
                  do istep = 1, nsteps
      
      ! --> Output current info to logfile.
                     if (nid == 0) then
                        write(*,*) 'nekstab_solver with :',trim(solver_type),' ifbase, ifpert, ifadj=',ifbase,ifpert,ifadj
                        if (findiff_order > 1) then
                           write (6, "(' ', A17,' (',I1,'/',I1,')' ':', I6, '/', I6, ' from', I5, '/', I5, ' [', I1, ']')")
     $   trim(solver_type), i, findiff_order, istep, nsteps, krylov_counter, k_dim, schur_cnt
                        else
                           write (6, "(' ', A17, ':', I6, '/', I6, ' from', I5, '/', I5, ' [', I1, ']')")
     $   trim(solver_type), istep, nsteps, krylov_counter, k_dim, schur_cnt
                        end if
                     end if
      
      !          --> Integrate in time.
                     omega_t = 0.0d0
                     if (index(solver_type, 'RESOLVENT') /= 0.0d0) then
                        omega_t = (2.0d0*pi/fintim)*time
      !              if omega_t NOT 0 then forcing is applied in nekStab_forcing
                     end if
                     call nekstab_usrchk()
                     call nek_advance()
                     matvec_counter = matvec_counter + 1
      
                     if (ifstorebase .and. ifbase .and. .not. orbit_stored) then !storing first time
      
                        if (nid == 0) write (*, *) 'storing orbit:', istep, '/', nsteps
                        call opcopy(uor(:, istep), vor(:, istep), wor(:, istep), vx, vy, vz)
                        if (ifto) call copy(tor(:, istep, 1), t(:, :, :, :, 1), nt)
                        if (ldimt > 1) then
                        do m = 2, ldimt
                           if (ifpsco(m - 1)) call copy(tor(:, istep, m), t(:, :, :, :, m), nt)
                        end do
                        end if
      
                     elseif (ifstorebase .and. .not. ifbase .and. orbit_stored) then !just moving in memory
      
                        if (nid == 0) write (*, *) 'using stored orbit:', istep, '/', nsteps
                        call opcopy(vx, vy, vz, uor(:, istep), vor(:, istep), wor(:, istep))
                        if (ifto) call copy(t(:, :, :, :, 1), tor(:, istep, 1), nt)
                        if (ldimt > 1) then
                        do m = 2, ldimt
                           if (ifpsco(m - 1)) call copy(t(:, :, :, :, m), tor(:, istep, m), nt)
                        end do
                        end if
      
                     end if
      
                  end do ! istep
      
                  if (ifstorebase .and. ifbase .and. .not. orbit_stored) then
                     ifbase = .false.; orbit_stored = .true. ! stop computing the base flow
                  end if
      
                  if (solver_type == 'DIRECT FD') then
      !          --> Copy the solution and compute the approximation of the Fréchet dérivative.
                     call nopcopy(work%vx, work%vy, work%vz, work%pr, work%t, vx, vy, vz, pr, t)
                     call nopcmult(work%vx, work%vy, work%vz, work%pr, work%t, coefs(i))
                     call nopadd2(out%vx, out%vy, out%vz, out%pr, out%t, work%vx, work%vy, work%vz, work%pr, work%t)
                  end if
      
               end do
      
               if (solver_type == 'DIRECT FD') then
      !           Rescale the approximate Fréchet derivative with the step size.
                  call nopcmult(out%vx, out%vy, out%vz, out%pr, out%t, 1.0d0/epsilon0)
               else
      !           --> Copy the solution.
                  call nopcopy(out%vx, out%vy, out%vz, out%pr, out%t, vxp(:, 1), vyp(:, 1), vzp(:, 1), prp(:, 1), tp(:, :, 1))
               end if
      
               if (nid == 0) then
                  write (*, *) 'matvec_counter=', matvec_counter
                  open (unit=10, file='matvec_counter.dat', status='unknown', position='append', form='formatted')
                  write (10, "(2I10)") krylov_counter, matvec_counter
                  close (10)
               end if
      
               krylov_counter = krylov_counter + 1
      
            end subroutine nekstab_solver
      
      !-------------------------------------------------------------------
      !-----     TYPE-BOUND PROCEDURE FOR THE RESOLVENT OPERATOR     -----
      !-------------------------------------------------------------------
      
            subroutine direct_map(self, vec_in, vec_out)
      
               implicit none
               class(resolvent_op), intent(in) :: self
               class(abstract_vector), intent(in) :: vec_in
               class(abstract_vector), intent(out) :: vec_out
               logical, save :: orbit_alocated = .false.
      
               select type (vec_in)
               type is (cmplx_nek_vector)
                  select type (vec_out)
                  type is (cmplx_nek_vector)
                     call setupLinearSolver('DIRECT   ', orbit_alocated)
                     call resolvent_solver('DIRECT   ', orbit_alocated, vec_in, vec_out)
                  end select
               end select
            end subroutine direct_map
      
            subroutine adjoint_map(self, vec_in, vec_out)
      
               implicit none
               class(resolvent_op), intent(in) :: self
               class(abstract_vector), intent(in) :: vec_in
               class(abstract_vector), intent(out) :: vec_out
               logical, save :: orbit_alocated = .false.
      
               select type (vec_in)
               type is (cmplx_nek_vector)
                  select type (vec_out)
                  type is (cmplx_nek_vector)
                     call setupLinearSolver('ADJOINT  ', orbit_alocated)
                     call resolvent_solver('ADJOINT  ', orbit_alocated, vec_in, vec_out)
                  end select
               end select
            end subroutine adjoint_map
      
            subroutine resolvent_solver(solver_type, orbit_alocated, vec_in, vec_out)
               use NekVectors
               implicit none
               include 'SIZE'
               include 'TOTAL'
               include 'ADJOINT'
      
               character(len=*), intent(in) :: solver_type
               logical, intent(inout) :: orbit_alocated
      ! type(abstract_vector), intent(in) :: vec_in
      ! type(abstract_vector), intent(out) :: vec_out
               type(cmplx_nek_vector), intent(in) :: vec_in
               type(cmplx_nek_vector), intent(out) :: vec_out
      
      !> Exponential propagator.
               class(exponential_prop), allocatable :: A
               class(identity_linop), allocatable :: Id
               class(axpby_linop), allocatable :: S
               class(real_nek_vector), allocatable :: b
               type(gmres_opts) :: opts
               integer :: info
               integer, save :: resolvent_counter = 1
               real :: tol
      
               tol = max(param(21), param(22))
               Id = identity_linop()
               A = exponential_prop(fintim)
      
               if (nid == 0) write (*, *) 'Starting resolvent solver, iteration:', resolvent_counter
      
      ! select type (vec_in)
      ! type is (cmplx_nek_vector)
      
      ! select type (vec_out)
      !    type is (cmplx_nek_vector)
      
      !>       Compute the right-hand side vector for gmres.
               allocate (b, source=vec_in%re); call b%zero()
      
               ! call outpost2(vec_in%re%vx, vec_in%re%vy, vec_in%re%vz, vec_in%re%pr, vec_in%re%t, nof, 'fRr')
               ! call outpost2(vec_in%im%vx, vec_in%im%vy, vec_in%im%vz, vec_in%im%pr, vec_in%im%t, nof, 'fRi')
      
      !> Sets the forcing spacial support.
               call nopcopy(fR_Re_u, fR_Re_v, fR_Re_w, fR_Re_p, fR_Re_t,
     $   vec_in%re%vx, vec_in%re%vy, vec_in%re%vz, vec_in%re%pr, vec_in%re%t)
               call nopcopy(fR_Im_u, fR_Im_v, fR_Im_w, fR_Im_p, fR_Im_t,
     $   vec_in%im%vx, vec_in%im%vy, vec_in%im%vz, vec_in%im%pr, vec_in%im%t)
      
               call outpost2(fR_Re_u, fR_Re_v, fR_Re_w, fR_Re_p, fR_Re_t, nof, 'fRr')
               call outpost2(fR_Im_u, fR_Im_v, fR_Im_w, fR_Im_p, fR_Im_t, nof, 'fRi')
      
      !>       Compute int_{0}^time exp( (t-s)*A ) * f(s) ds                       ! result in b
               call nekstab_solver(trim('RESOLVENT '//solver_type), orbit_alocated, vec_in%re, b)
      
               call outpost2(b%vx, b%vy, b%vz, b%pr, b%t, nof, 'bRr')
      
      !>       GMRES solve to compute the post-transient response.
               opts = gmres_opts(verbose=.true., atol=tol, rtol=tol)
               S = axpby_linop(Id, A, 1.0d0, -1.0d0, .false., .true.)
      
      ! prepare solvef here ?
      
               if (index(solver_type, 'DIRECT') > 0) then
                  if (nid == 0) write (*, *) 'gmres S b vec_out%re transpose=T'
                  call gmres(S, b, vec_out%re, info, options=opts, transpose=.true.)
               else if (index(solver_type, 'ADJOINT') > 0) then
                  if (nid == 0) write (*, *) 'gmres S b vec_out%re transpose=F'
                  call gmres(S, b, vec_out%re, info, options=opts, transpose=.false.)
               end if
      
               A = exponential_prop(fintim*0.25d0) ! integrate for 1/4 of the time
      !        A%t = A%t*0.25D0
               if (nid == 0) write (*, *) 'integrating for 1/4 of the time:', A%t
               call direct_solver(A, vec_out%re, vec_out%im)
               call outpost2(vec_out%re%vx, vec_out%re%vy, vec_out%re%vz, vec_out%re%pr, vec_out%re%t, nof, 'oRr')
               call outpost2(vec_out%im%vx, vec_out%im%vy, vec_out%im%vz, vec_out%im%pr, vec_out%im%t, nof, 'oRi')
      
      !    end select
      ! end select
      
               if (nid == 0) write (*, *) 'Resolvent solver finished.'
               resolvent_counter = resolvent_counter + 1
      
            end subroutine resolvent_solver
      
         end module LinearOperators
