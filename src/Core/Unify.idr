module Core.Unify

import Core.CaseTree
import Core.Context
import Core.Normalise
import Core.TT
import public Core.UnifyState

import Data.List
import Data.List.Views
import Data.CSet

%default covering

public export
data UnifyMode = InLHS
               | InTerm

public export
interface Unify (tm : List Name -> Type) where
  -- Unify returns a list of names referring to newly added constraints
  unifyD : Ref Ctxt Defs ->
           Ref UST (UState annot) ->
           UnifyMode ->
           annot -> Env Term vars ->
           tm vars -> tm vars -> 
           Core annot (List Name)

-- Workaround for auto implicits not working in interfaces
export
unify : Unify tm => 
           {auto c : Ref Ctxt Defs} ->
           {auto u : Ref UST (UState annot)} ->
           UnifyMode ->
           annot -> Env Term vars ->
           tm vars -> tm vars -> 
           Core annot (List Name)
unify {c} {u} = unifyD c u

ufail : annot -> String -> Core annot a
ufail loc msg = throw (GenericMsg loc msg)

convertError : annot -> Env Term vars -> Term vars -> Term vars -> Core annot a
convertError loc env x y = throw (CantConvert loc env x y)

-- Given a name, which must currently be a hole, attempt to fill in the hole with
-- an expression which would fit. Also returns the expression.
-- (Defined in AutoSearch; we need this when searching arguments recursively
-- too and we need to invoke it during unification, so this is to avoid
-- cycles in module imports)
export
search : {auto c : Ref Ctxt Defs} ->
         {auto u : Ref UST (UState annot)} ->
         annot -> Nat -> List ClosedTerm -> Name -> Name -> Core annot ClosedTerm

-- try one elaborator; if it fails, try another
export
try : {auto c : Ref Ctxt Defs} -> {auto e : Ref UST (UState annot)} ->
      Core annot a -> Core annot a -> Core annot a
try elab1 elab2
    = do ctxt <- get Ctxt
         ust <- get UST
         catch elab1
               (\err => case err of
                             Fatal e => throw e
                             _ => do put Ctxt ctxt
                                     put UST ust
                                     elab2)

-- try one elaborator; if it fails, try another
export
handleError : {auto c : Ref Ctxt Defs} -> {auto e : Ref UST (UState annot)} ->
      Core annot a -> (Error annot -> Core annot a) -> Core annot a
handleError elab1 elab2
    = do ctxt <- get Ctxt
         ust <- get UST
         catch elab1
               (\err => case err of
                             Fatal e => throw e
                             _ => do put Ctxt ctxt
                                     put UST ust
                                     elab2 err)

unifyArgs : (Unify tm, Quote tm) =>
            {auto c : Ref Ctxt Defs} ->
            {auto u : Ref UST (UState annot)} ->
            UnifyMode -> annot -> Env Term vars ->
            List (tm vars) -> List (tm vars) ->
            Core annot (List Name)
unifyArgs mode loc env [] [] = pure []
unifyArgs mode loc env (cx :: cxs) (cy :: cys)
    = do constr <- unify mode loc env cx cy
         case constr of
              [] => unifyArgs mode loc env cxs cys
              _ => do gam <- get Ctxt 
                      cs <- unifyArgs mode loc env cxs cys
                      -- TODO: Fix this bit! See p59 Ulf's thesis
--                       c <- addConstraint 
--                                (MkSeqConstraint loc env 
--                                    (map (quote gam env) (cx :: cxs))
--                                    (map (quote gam env) (cy :: cys)))
                      pure (union constr cs) -- [c]
unifyArgs mode loc env _ _ = ufail loc ""

postpone : {auto c : Ref Ctxt Defs} ->
           {auto u : Ref UST (UState annot)} ->
           annot -> Env Term vars ->
           Term vars -> Term vars ->
           Core annot (List Name)
postpone loc env x y
    = do c <- addConstraint (MkConstraint loc env x y)
         pure [c]

-- Get the variables in an application argument list; fail if any arguments 
-- are not variables, fail if there's any repetition of variables
-- We use this to check that the pattern unification rule is applicable
-- when solving a metavariable applied to arguments
getVars : List (NF vars) -> Maybe (List (x ** Elem x vars))
getVars [] = Just []
getVars (NApp (NLocal v) [] :: xs) 
    = if vIn xs then Nothing
         else do xs' <- getVars xs
                 pure ((_ ** v) :: xs')
  where
    -- Check the variable doesn't appear later
    vIn : List (NF vars) -> Bool
    vIn [] = False
    vIn (NApp (NLocal el') [] :: xs)
        = if sameVar v el' then True else vIn xs
    vIn (_ :: xs) = vIn xs
getVars (_ :: xs) = Nothing

-- Make a sublist representing the variables used in the application.
-- We'll use this to ensure that local variables which appear in a term
-- are all arguments to a metavariable application for pattern unification
toSubVars : (vars : List Name) -> List (x ** Elem x vars) ->
            (newvars ** SubVars newvars vars)
toSubVars [] xs = ([] ** SubRefl)
toSubVars (n :: ns) xs 
     -- If there's a proof 'Here' in 'xs', then 'n' should be kept,
     -- otherwise dropped
     -- (Remember: 'n' might be shadowed; looking for 'Here' ensures we
     -- get the *right* proof that the name is in scope!)
     = let (_ ** svs) = toSubVars ns (dropHere xs) in
           if anyHere xs 
              then (_ ** KeepCons svs)
              else (_ ** DropCons svs)
  where
    anyHere : List (x ** Elem x (n :: ns)) -> Bool
    anyHere [] = False
    anyHere ((_ ** Here) :: xs) = True
    anyHere ((_ ** There p) :: xs) = anyHere xs

    dropHere : List (x ** Elem x (n :: ns)) -> List (x ** Elem x ns) 
    dropHere [] = []
    dropHere ((_ ** Here) :: xs) = dropHere xs
    dropHere ((_ ** There p) :: xs) = (_ ** p) :: dropHere xs

{- Applying the pattern unification rule is okay if:
   * Arguments are all distinct local variables
   * The metavariable name doesn't appear in the unifying term
   * The local variables which appear in the term are all arguments to
     the metavariable application (not checked here, checked with the
     result of `patternEnv`)

   Return the subset of the environment used in the arguments
   to which the metavariable is applied. If this environment is enough
   to check the term we're unifying with, and that term doesn't use the
   metavariable name, we can safely apply the rule.
-}
patternEnv : {auto c : Ref Ctxt Defs} ->
             {auto u : Ref UST (UState annot)} ->
             Env Term vars -> List (Closure vars) -> 
             Core annot (Maybe (newvars ** SubVars newvars vars))
patternEnv env args
    = do defs <- get Ctxt
         let args' = map (evalClosure (noGam defs)) args
         case getVars args' of
              Nothing => pure Nothing
              Just vs => pure (Just (toSubVars _ vs))

-- Instantiate a metavariable by binding the variables in 'newvars'
-- and returning the term
-- If the type of the metavariable doesn't have enough arguments, fail, because
-- this wasn't valid for pattern unification
instantiate : {auto c : Ref Ctxt Defs} ->
              {auto u : Ref UST (UState annot)} ->
              annot ->
              (metavar : Name) -> SubVars newvars vars -> Term newvars ->
              Core annot ()
instantiate loc metavar smvs tm {newvars}
     = do gam <- get Ctxt
          -- If the name is user defined, it means we've solved a ?hole by
          -- unification, which is not what we want!
          when (isUserName metavar) $
               throw (SolvedNamedHole loc metavar)
          case lookupDefTyExact metavar (gamma gam) of
               Nothing => ufail loc $ "No such metavariable " ++ show metavar
               Just (_, ty) => 
                    case mkRHS [] newvars CompatPre ty 
                             (rewrite appendNilRightNeutral newvars in tm) of
                         Nothing => ufail loc $ "Can't make solution for " ++ show metavar
                         Just rhs => 
                            do let soln = newDef ty Public 
                                               (PMDef True [] (STerm rhs))
                               log 7 $ "Instantiate: " ++ show metavar ++
                                            " = " ++ show rhs
                               addDef metavar soln
                               removeHoleName metavar
  where
    mkRHS : (got : List Name) -> (newvars : List Name) ->
            CompatibleVars got rest ->
            Term rest -> Term (newvars ++ got) -> Maybe (Term rest)
    mkRHS got ns cvs ty tm with (snocList ns)
      mkRHS got [] cvs ty tm | Empty = Just (renameVars cvs tm)
      mkRHS got (ns ++ [n]) cvs (Bind x (Pi c _ ty) sc) tm | (Snoc rec) 
           = do sc' <- mkRHS (n :: got) ns (CompatExt cvs) sc 
                           (rewrite appendAssociative ns [n] got in tm)
                pure (Bind x (Lam c Explicit ty) sc')
      -- Run out of variables to bind
      mkRHS got (ns ++ [n]) cvs ty tm | (Snoc rec) = Nothing

export
implicitBind : {auto c : Ref Ctxt Defs} ->
               {auto u : Ref UST (UState annot)} ->
               Name -> Core annot ()
implicitBind n 
    = do gam <- get Ctxt
         case lookupDefExact n (gamma gam) of
              Just (Hole len _) => updateDef n ImpBind
              _ => pure ()

-- Check that the references in the term don't refer to the hole name as
-- part of their definition
occursCheck : Defs -> Name -> Term vars -> Bool
occursCheck gam n tm 
    = case oc empty tm of
           Nothing => False
           Just _ => True
  where
    -- Remember the ones we've checked as okay already, to save repeating work
    oc : (checked : SortedSet) -> Term vars -> Maybe SortedSet
    oc chk (Ref nt var)
        -- if 'var' or one of its descendents is 'n' we fail the check
        -- otherwise add it to the set of checked things
        = if contains var chk 
             then Just chk
             else if var == n 
               then Nothing
               else let ns = getDescendents var (gamma gam) in
                        if n `elem` ns
                           then Nothing
                           else Just (insert var chk)
    oc chk (Bind n (Let _ val ty) sc)
        = do vchk <- oc chk val
             tchk <- oc vchk ty
             oc tchk sc
    oc chk (Bind n b sc)
        = do bchk <- oc chk (binderType b)
             oc bchk sc
    oc chk (App f a)
        = do fchk <- oc chk f
             oc fchk a
    oc chk tm = Just chk
       
-- Convert corresponding lists of reversedarguments. Returns the fragment 
-- which don't convert (as long as at least one pair does convert)
convertAll : Defs -> Env Term vars -> 
             List (Closure vars) -> List (Closure vars) -> 
             Maybe (List (Closure vars), List (Closure vars))
convertAll {vars} defs env xs ys = convertP False xs ys
  where
    convertP : (progress : Bool) -> 
               List (Closure vars) -> List (Closure vars) ->
               Maybe (List (Closure vars), List (Closure vars))
    convertP False as [] = Nothing
    convertP True as [] = Just (reverse as, [])
    convertP _ (x :: xs) (y :: ys)
        = if convert defs env x y 
             then convertP True xs ys
             else Just (reverse (x :: xs), reverse (y :: ys))
    convertP _ _ _ = Nothing

mutual
  -- Find holes which are applied to environments which are too big, and
  -- solve them with a new hole applied to only the available arguments.
  -- Essentially what this achieves is moving a hole to an outer scope where
  -- it solution is now usable
  export
  shrinkHoles : {auto c : Ref Ctxt Defs} ->
                {auto u : Ref UST (UState annot)} ->
                annot -> Env Term vars ->
                List (Term vars) -> Term vars ->
                Core annot (Term vars)
  shrinkHoles loc env args (Bind x (Let c val ty) sc) 
      = do val' <- shrinkHoles loc env args val
           ty' <- shrinkHoles loc env args ty
           sc' <- shrinkHoles loc (Let c val ty :: env) (map weaken args) sc
           pure (Bind x (Let c val' ty') sc')
  shrinkHoles loc env args (Bind x b sc) 
      = do let bty = binderType b
           bty' <- shrinkHoles loc env args bty
           sc' <- shrinkHoles loc (b :: env) (map weaken args) sc
           pure (Bind x (setType b bty') sc')
  shrinkHoles loc env args tm with (unapply tm)
    shrinkHoles loc env args (apply (Ref Func h) as) | ArgsList 
         = do gam <- get Ctxt
              -- If the hole we're trying to solve (in the call to 'shrinkHoles')
              -- doesn't have enough arguments to be able to pass them to
              -- 'h' here, make a new hole 'sh' which only uses the available
              -- arguments, and solve h with it.
              case lookupDefTyExact h (gamma gam) of
                   Just (Hole _ _, ty) => 
                        do sn <- genName "sh"
                           mkSmallerHole loc [] ty h as sn args
                   _ => pure (apply (Ref Func h) as)
    shrinkHoles loc env args (apply f []) | ArgsList 
         = pure f
    shrinkHoles loc env args (apply f as) | ArgsList 
         = do f' <- shrinkHoles loc env args f
              as' <- traverse (\x => shrinkHoles loc env args x) as
              pure (apply f' as')

  -- if 'argPrefix' is a complete valid prefix of 'args', and all the arguments
  -- are local variables, and none of the other arguments in 'args' are
  -- used in the goal type, then create a new hole 'newhole' which takes that
  -- prefix as arguments. 
  -- Then, solve 'oldhole' by applying 'newhole' to 'argPrefix'
  mkSmallerHole : {auto c : Ref Ctxt Defs} ->
                  {auto u : Ref UST (UState annot)} ->
                  annot ->
                  (eqsofar : List (Term vars)) ->
                  (holetype : ClosedTerm) ->
                  (oldhole : Name) ->
                  (args : List (Term vars)) ->
                  (newhole : Name) ->
                  (argPrefix : List (Term vars)) ->
                  Core annot (Term vars)
  mkSmallerHole loc sofar holetype oldhole 
                              (Local arg :: args) newhole (Local a :: as)
      = if sameVar arg a
           then mkSmallerHole loc (sofar ++ [Local a]) holetype oldhole
                              args newhole as
           else pure (apply (Ref Func oldhole) (sofar ++ args))
  -- We have the right number of arguments, so the hole is usable in this
  -- context.
  mkSmallerHole loc sofar holetype oldhole [] newhole []
      = pure (apply (Ref Func oldhole) sofar)
  mkSmallerHole loc sofar holetype oldhole args newhole []
  -- Reached a prefix of the arguments, so make a new hole applied to 'sofar'
  -- and use it to solve 'oldhole', as long as the omitted arguments aren't
  -- needed for it.
      = case newHoleType sofar holetype of
             Nothing => ufail loc $ "Can't shrink hole"
             Just defty =>
                do -- Make smaller hole
                   let hole = newDef defty Public (Hole (length sofar) False)
                   addHoleName loc newhole
                   addDef newhole hole
                   -- Solve old hole with it
                   case mkOldHoleDef holetype newhole sofar (sofar ++ args) of
                        Nothing => ufail loc $ "Can't shrink hole"
                        Just olddef =>
                           do let soln = newDef defty Public
                                              (PMDef True [] (STerm olddef))
                              addDef oldhole soln
                              removeHoleName oldhole
                              pure (apply (Ref Func newhole) sofar)
  -- Default case, leave the hole application as it is
  mkSmallerHole loc sofar holetype oldhole args _ _
      = pure (apply (Ref Func oldhole) (sofar ++ args))

  -- Drop the pi binders from the front of a term. This is only valid if
  -- the name is not used in the scope
  dropBinders : SubVars vars (drop ++ vars) -> 
                Term (drop ++ vars) -> Maybe (Term vars)
  dropBinders {drop} subprf (Bind n (Pi _ imp ty) scope)
    = dropBinders {drop = n :: drop} (DropCons subprf) scope
  dropBinders subprf tm = shrinkTerm tm subprf

  newHoleType : List (Term vars) -> Term hvars -> Maybe (Term hvars)
  newHoleType [] tm = dropBinders {drop = []} SubRefl tm
  newHoleType (x :: xs) (Bind n (Pi c imp ty) scope) 
      = do scope' <- newHoleType xs scope
           pure (Bind n (Pi c imp ty) scope')
  newHoleType _ _ = Nothing

  mkOldHoleDef : Term hargs -> Name ->
                 List (Term vars) -> List (Term vars) ->
                 Maybe (Term hargs)
  mkOldHoleDef (Bind x (Pi c _ ty) sc) newh sofar (a :: args)
      = do sc' <- mkOldHoleDef sc newh sofar args
           pure (Bind x (Lam c Explicit ty) sc')
  mkOldHoleDef {hargs} {vars} ty newh sofar args
      = do compat <- areVarsCompatible vars hargs
           let newargs = map (renameVars compat) sofar
           pure (apply (Ref Func newh) newargs)
  
  isHoleNF : Gamma -> Name -> Bool
  isHoleNF gam n
      = case lookupDefExact n gam of
             Just (Hole _ pvar) => not pvar
             _ => False
  
  unifyHoleApp : {auto c : Ref Ctxt Defs} ->
                 {auto u : Ref UST (UState annot)} ->
                 UnifyMode -> annot -> Env Term vars ->
                 NameType -> Name -> List (Closure vars) -> NF vars ->
                 Core annot (List Name)
  unifyHoleApp mode loc env nt var args (NTCon n t a args')
      = do gam <- get Ctxt
           -- Convert arguments right to left, then unify the head with
           -- the type. Arguments must be convertible (not merely unifiable)
           -- and there must be at least one consumed
           case convertAll gam env (reverse args) (reverse args') of
                Just (fargs, targs) => 
                   do log 10 $ "Continuing with " ++
                            show (quote (noGam gam) env (NApp (NRef nt var) fargs))
                              ++ " =?= " ++
                            show (quote (noGam gam) env (NTCon n t a targs))
                      unify mode loc env (NApp (NRef nt var) fargs) 
                                         (NTCon n t a targs)
                Nothing =>
                   do log 10 $ "Postponing hole application " ++
                            show (quote (noGam gam) env (NApp (NRef nt var) args)) ++ " =?= " ++
                            show (quote (noGam gam) env (NTCon n t a args'))
                      postpone loc env
                           (quote (noGam gam) env (NApp (NRef nt var) args)) 
                           (quote (noGam gam) env (NTCon n t a args'))
  unifyHoleApp mode loc env nt var args (NDCon n t a args')
      = do gam <- get Ctxt
           -- Convert arguments right to left, then unify the head with
           -- the type. Arguments must be convertible (not merely unifiable)
           -- and there must be at least one consumed
           case convertAll gam env (reverse args) (reverse args') of
                Just (fargs, targs) => 
                   do log 10 $ "Continuing with " ++
                            show (quote (noGam gam) env (NApp (NRef nt var) fargs))
                              ++ " =?= " ++
                            show (quote (noGam gam) env (NDCon n t a targs))
                      unify mode loc env (NApp (NRef nt var) fargs) 
                                         (NDCon n t a targs)
                Nothing =>
                   do log 10 $ "Postponing hole application " ++
                            show (quote (noGam gam) env (NApp (NRef nt var) args)) ++ " =?= " ++
                            show (quote (noGam gam) env (NDCon n t a args'))
                      postpone loc env
                           (quote (noGam gam) env (NApp (NRef nt var) args)) 
                           (quote (noGam gam) env (NDCon n t a args'))
  unifyHoleApp mode loc env nt var args (NApp (NLocal lvar) args')
      = do gam <- get Ctxt
           -- Convert arguments right to left, then unify the head with
           -- the type. Arguments must be convertible (not merely unifiable)
           case convertAll gam env (reverse args) (reverse args') of
                Just (fargs, targs) => 
                    unify mode loc env (NApp (NRef nt var) fargs) 
                                       (NApp (NLocal lvar) targs)
                Nothing =>
                   do log 10 $ "Postponing hole application " ++
                            show (quote (noGam gam) env (NApp (NRef nt var) args)) ++ " =?= " ++
                            show (quote (noGam gam) env (NApp (NLocal lvar) args'))
                      postpone loc env
                           (quote (noGam gam) env (NApp (NRef nt var) args)) 
                           (quote (noGam gam) env (NApp (NLocal lvar) args'))
  unifyHoleApp mode loc env nt var args tm
      = do gam <- get Ctxt
           log 10 $ "Postponing constraint " ++
                        show (quote (noGam gam) env (NApp (NRef nt var) args))
                         ++ " =?= " ++
                        show (quote (noGam gam) env tm)
           postpone loc env 
                 (quote (noGam gam) env (NApp (NRef nt var) args))
                 (quote (noGam gam) env tm)

  unifyHole : {auto c : Ref Ctxt Defs} ->
              {auto u : Ref UST (UState annot)} ->
              UnifyMode -> annot -> Env Term vars ->
              NameType -> Name -> List (Closure vars) -> NF vars ->
              Core annot (List Name)
  unifyHole mode loc env nt var args tm
   = do gam <- get Ctxt
        log 10 $ "Unifying: " ++ show var ++ " " ++
                                 show (map (\t => quote (noGam gam) env (evalClosure (noGam gam) t)) args) ++
                 " with " ++ show (quote (noGam gam) env tm)
        case !(patternEnv env args) of
           Just (newvars ** submv) =>
                do log 10 $ "Progress: " ++ show newvars
                   gam <- get Ctxt
--                    tm' <- shrinkHoles loc env (map (quote gam env) args) 
--                                               (quote gam env tm)
--                    gam <- get Ctxt
                   -- newvars and args should be the same length now, because
                   -- there's one new variable for each distinct argument.
                   -- The types don't express this, but 'submv' at least
                   -- tells us that 'newvars' are the subset of 'vars'
                   -- being applied to the metavariable, and so 'tm' must
                   -- only use those variables for success
                   case shrinkTerm (normaliseHoles gam env (quote (noGam gam) env tm)) submv of
                        Nothing => do
                           log 10 $ "Postponing constraint " ++
                                      show (quote (noGam gam) env (NApp (NRef nt var) args))
                                       ++ " =?= " ++
                                      show (quote (noGam gam) env tm)
                           postpone loc env 
                             (quote (noGam gam) env (NApp (NRef nt var) args))
                             (quote (noGam gam) env tm)
--                              ufail loc $ "Scope error " ++
--                                    show (vars, newvars) ++
--                                    "\nUnifying " ++
--                                    show (quote gam env
--                                            (NApp (NRef nt var) args)) ++
--                                    " and "
--                                    ++ show (quote gam env tm)
                        Just tm' => 
                            -- if the terms are the same, this isn't a solution
                            -- but they are already unifying, so just return
                            if convert (noGam gam) env (NApp (NRef nt var) args) tm
                               then pure []
                               else
                                -- otherwise, instantiate the hole as long as
                                -- the solution doesn't refer to the hole
                                -- name
                                   if not (occursCheck gam var tm')
                                      then throw (Cycle loc env
                                                 (normaliseHoles gam env
                                                     (quote (noGam gam) env (NApp (NRef nt var) args)))
                                                 (normaliseHoles gam env
                                                     (quote (noGam gam) env tm)))
                                      else do instantiate loc var submv tm'
                                              pure []
           -- Not in the pattern fragment
           Nothing => do log 10 $ "Not in pattern fragment"
                         gam <- get Ctxt
--                          postpone loc env
--                              (quote (noGam gam) env (NApp (NRef nt var) args))
--                              (quote (noGam gam) env tm)
                         unifyHoleApp mode loc env nt var args tm

  unifyApp : {auto c : Ref Ctxt Defs} ->
             {auto u : Ref UST (UState annot)} ->
             UnifyMode -> annot -> Env Term vars ->
             NHead vars -> List (Closure vars) -> NF vars ->
             Core annot (List Name)
  unifyApp mode loc env (NRef nt var) args tm 
      = do gam <- get Ctxt
           if convert (noGam gam) env (NApp (NRef nt var) args) tm
              then pure []
              else
               if isHoleNF (gamma gam) var
                  then unifyHole mode loc env nt var args tm
                  else unifyIfEq True loc env (NApp (NRef nt var) args) tm
  unifyApp mode loc env hd args (NApp (NRef nt var) args')
      = do gam <- get Ctxt
           if convert (noGam gam) env (NApp hd args) (NApp (NRef nt var) args')
              then pure []
              else
                if isHoleNF (gamma gam) var
                   then unifyHole mode loc env nt var args' (NApp hd args)
                   else unifyIfEq True loc env (NApp hd args)
                                               (NApp (NRef nt var) args')
  unifyApp mode loc env (NLocal x) [] (NApp (NLocal y) [])
      = do gam <- get Ctxt
           if sameVar x y then pure []
             else do log 10 $ "Postponing var constraint " ++
                              show (quote (noGam gam) env (NApp (NLocal x) [])) ++ 
                              " =?= " ++ 
                              show (quote (noGam gam) env (NApp (NLocal y) []))
                     postpone loc env
                       (quote (noGam gam) env (NApp (NLocal x) [])) 
                       (quote (noGam gam) env (NApp (NLocal y) []))
  unifyApp mode loc env hd args (NApp hd' args')
      = do gam <- get Ctxt
           if convert (noGam gam) env (NApp hd args) (NApp hd' args')
             then pure []
             else do log 10 $ "Postponing constraint " ++
                              show (quote (noGam gam) env (NApp hd args)) ++ " =?= " ++
                              show (quote (noGam gam) env (NApp hd' args))
                     postpone loc env
                              (quote (noGam gam) env (NApp hd args)) 
                              (quote (noGam gam) env (NApp hd' args'))
  -- A local variable against a constructor is impossible, because the local
  -- should quantify over everything
  unifyApp mode loc env (NLocal x) [] (NDCon n t a args)
      = do gam <- get Ctxt
           convertError loc env  
               (quote (noGam gam) env (NApp (NLocal x) []))
               (quote (noGam gam) env (NDCon n t a args))
  unifyApp mode loc env (NLocal x) [] (NTCon n t a args)
      = do gam <- get Ctxt
           convertError loc env (quote (noGam gam) env (NApp (NLocal x) []))
                        (quote (noGam gam) env (NTCon n t a args))
  -- If they're already convertible without metavariables, we're done,
  -- otherwise postpone
  unifyApp mode loc env hd args tm 
      = do gam <- get Ctxt
           if convert gam env (quote (noGam gam) env (NApp hd args))
                              (quote (noGam gam) env tm)
              then pure []
              else do log 10 $ "Catch all case: Postponing constraint " ++
                            show (quote (noGam gam) env (NApp hd args)) ++ " =?= " ++
                            show (quote (noGam gam) env tm)
                      postpone loc env
                           (quote (noGam gam) env (NApp hd args)) (quote (noGam gam) env tm)
  
  unifyBothApps
           : {auto c : Ref Ctxt Defs} ->
             {auto u : Ref UST (UState annot)} ->
             UnifyMode -> annot -> Env Term vars ->
             NHead vars -> List (Closure vars) -> 
             NHead vars -> List (Closure vars) ->
             Core annot (List Name)
  unifyBothApps _ loc env (NLocal xv) [] (NLocal yv) []
     = do gam <- get Ctxt
          if sameVar xv yv
            then pure []
            else convertError loc env 
                             (quote (noGam gam) env (NApp (NLocal xv) []))
                             (quote (noGam gam) env (NApp (NLocal yv) []))
  -- Locally bound things, in a term (not LHS). Since we have to unify
  -- for *all* possible values, we can safely unify the arguments.
  unifyBothApps InTerm loc env (NLocal xv) argsx (NLocal yv) argsy
     = do gam <- get Ctxt
          if sameVar xv yv
            then unifyArgs InTerm loc env argsx argsy
            else do log 10 $ "Postponing constraint (locals) " ++
                             show (quote (noGam gam) env (NApp (NLocal xv) argsx))
                             ++ " =?= " ++
                             show (quote (noGam gam) env (NApp (NLocal yv) argsy))
                    postpone loc env (quote (noGam gam) env (NApp (NLocal xv) argsx))
                                     (quote (noGam gam) env (NApp (NLocal yv) argsy))
  unifyBothApps _ loc env (NLocal xv) argsx (NLocal yv) argsy
      = do gam <- get Ctxt
           log 10 $ "Postponing constraint (locals, LHS) " ++
                     show (quote (noGam gam) env (NApp (NLocal xv) argsx))
                     ++ " =?= " ++
                     show (quote (noGam gam) env (NApp (NLocal yv) argsy))
           postpone loc env (quote (noGam gam) env (NApp (NLocal xv) argsx))
                            (quote (noGam gam) env (NApp (NLocal yv) argsy))
  -- If they're both holes, solve the one with the bigger context with
  -- the other
  unifyBothApps mode loc env (NRef xt hdx) argsx (NRef yt hdy) argsy
      = do gam <- get Ctxt
           if isHoleNF (gamma gam) hdx && isHoleNF (gamma gam) hdy
              then
                 (if length argsx > length argsy
                     then unifyApp mode loc env (NRef xt hdx) argsx 
                                           (NApp (NRef yt hdy) argsy)
                     else unifyApp mode loc env (NRef yt hdy) argsy 
                                           (NApp (NRef xt hdx) argsx))
              else 
                 (if isHoleNF (gamma gam) hdx
                     then unifyApp mode loc env (NRef xt hdx) argsx
                                           (NApp (NRef yt hdy) argsy)
                     else unifyApp mode loc env (NRef yt hdy) argsy 
                                           (NApp (NRef xt hdx) argsx))
  unifyBothApps mode loc env fx ax fy ay
        = unifyApp mode loc env fx ax (NApp fy ay)
  
  unifyBothBinders
           : {auto c : Ref Ctxt Defs} ->
             {auto u : Ref UST (UState annot)} ->
             UnifyMode -> annot -> Env Term vars ->
             Name -> Binder (NF vars) -> (Closure vars -> NF vars) ->
             Name -> Binder (NF vars) -> (Closure vars -> NF vars) ->
             Core annot (List Name)
  unifyBothBinders mode loc env x (Pi cx ix tx) scx y (Pi cy iy ty) scy
      = do gam <- get Ctxt
           if ix /= iy && cx /= cy
             then convertError loc env 
                    (quote (noGam gam) env (NBind x (Pi cx ix tx) scx))
                    (quote (noGam gam) env (NBind y (Pi cy iy ty) scy))
             else
               do ct <- unify mode loc env tx ty
                  xn <- genName "x"
                  let env' : Env Term (x :: _)
                           = Pi cx ix (quote (noGam gam) env tx) :: env
                  case ct of
                       [] => -- no constraints, check the scope
                             do let tscx = scx (toClosure False env (Ref Bound xn))
                                let tscy = scy (toClosure False env (Ref Bound xn))
                                let termx = refToLocal xn x (quote (noGam gam) env tscx)
                                let termy = refToLocal xn x (quote (noGam gam) env tscy)
                                unify mode loc env' termx termy
                       cs => -- constraints, make new guarded constant
                             do let txtm = quote (noGam gam) env tx
                                let tytm = quote (noGam gam) env ty
                                c <- addConstant loc env
                                       (Bind x (Lam cx Explicit txtm) (Local Here))
                                       (Bind x (Pi cx Explicit txtm)
                                           (weaken tytm)) cs
                                let tscx = scx (toClosure False env (Ref Bound xn))
                                let tscy = scy (toClosure False env 
                                               (App (mkConstantApp c env) (Ref Bound xn)))
                                let termx = refToLocal xn x (quote (noGam gam) env tscx)
                                let termy = refToLocal xn x (quote (noGam gam) env tscy)
                                cs' <- unify mode loc env' termx termy
                                pure (union cs cs')
  unifyBothBinders mode loc env x (Lam cx ix tx) scx y (Lam cy iy ty) scy 
      = do gam <- get Ctxt
           if ix /= iy && cx /= cy
             then convertError loc env 
                     (quote (noGam gam) env (NBind x (Lam cx ix tx) scx))
                     (quote (noGam gam) env (NBind y (Lam cy iy ty) scy))
             else
               do csty <- unify mode loc env tx ty
                  xn <- genName "x"
                  let env' : Env Term (x :: _)
                           = Lam cx ix (quote (noGam gam) env tx) :: env
                  let tscx = scx (toClosure False env (Ref Bound xn))
                  let tscy = scy (toClosure False env (Ref Bound xn))
                  let termx = refToLocal xn x (quote (noGam gam) env tscx)
                  let termy = refToLocal xn x (quote (noGam gam) env tscy)
                  cssc <- unify mode loc env' termx termy
                  pure (union csty cssc)
  unifyBothBinders mode loc env x bx scx y by scy
      = do gam <- get Ctxt
           convertError loc env 
                  (quote (noGam gam) env (NBind x bx scx))
                  (quote (noGam gam) env (NBind x by scy))
  
  export
  Unify Closure where
    unifyD _ _ mode loc env x y 
        = do gam <- get Ctxt
             -- 'quote' using an empty global context, because then function
             -- names won't reduce until they have to
             let x' = quote (noGam gam) env x
             let y' = quote (noGam gam) env y
             unify mode loc env x' y'

  unifyIfEq : {auto c : Ref Ctxt Defs} ->
              {auto u : Ref UST (UState annot)} ->
              (postpone : Bool) ->
              annot -> Env Term vars -> NF vars -> NF vars -> 
                  Core annot (List Name)
  unifyIfEq post loc env x y 
        = do gam <- get Ctxt
             if convert gam env x y
                then pure []
                else if post 
                        then do log 10 $ "Postponing constraint (unifyIfEq) " ++
                                         show (quote (noGam gam) env x) ++ " =?= " ++
                                         show (quote (noGam gam) env y)
                                postpone loc env (quote (noGam gam) env x) (quote (noGam gam) env y)
                        else convertError loc env 
                                     (quote (noGam gam) env x)
                                     (quote (noGam gam) env y)

  export
  Unify NF where
    unifyD _ _ mode loc env (NBind x bx scx) (NBind y by scy) 
        = unifyBothBinders mode loc env x bx scx y by scy
    -- If one thing is a lambda and the other is a name applied to some
    -- arguments, eta expand and try again
    unifyD _ _ mode loc env tmx@(NBind x (Lam cx ix tx) scx) tmy
        = do gam <- get Ctxt
             let etay = nf gam env 
                           (Bind x (Lam cx ix (quote (noGam gam) env tx))
                                   (App (weaken (quote (noGam gam) env tmy)) (Local Here)))
             unify mode loc env tmx etay
    unifyD _ _ mode loc env tmx tmy@(NBind y (Lam cy iy ty) scy)
        = do gam <- get Ctxt
             let etax = nf gam env 
                           (Bind y (Lam cy iy (quote (noGam gam) env ty))
                                   (App (weaken (quote (noGam gam) env tmx)) (Local Here)))
             unify mode loc env etax tmy
    unifyD _ _ mode loc env (NDCon x tagx ax xs) (NDCon y tagy ay ys)
        = do gam <- get Ctxt
             if tagx == tagy
               then do log 5 ("Constructor " ++ show (quote (noGam gam) env (NDCon x tagx ax xs))
                                  ++ " and " ++ show (quote (noGam gam) env (NDCon y tagy ay ys)))
                       unifyArgs mode loc env xs ys
               else convertError loc env 
                         (quote (noGam gam) env (NDCon x tagx ax xs))
                         (quote (noGam gam) env (NDCon y tagy ay ys))
    unifyD _ _ mode loc env (NTCon x tagx ax xs) (NTCon y tagy ay ys)
        = do gam <- get Ctxt
             if tagx == tagy
               then do log 5 ("Constructor " ++ show (quote (noGam gam) env (NTCon x tagx ax xs))
                                  ++ " and " ++ show (quote (noGam gam) env (NTCon y tagy ay ys)))
                       unifyArgs mode loc env xs ys
               -- TODO: Type constructors are not necessarily injective.
               -- If we don't know it's injective, need to postpone the
               -- constraint. But before then, we need some way to decide
               -- what's injective...
--                then postpone loc env (quote empty env (NTCon x tagx ax xs))
--                                      (quote empty env (NTCon y tagy ay ys))
               else convertError loc env 
                         (quote (noGam gam) env (NTCon x tagx ax xs))
                         (quote (noGam gam) env (NTCon y tagy ay ys))
    unifyD _ _ mode loc env (NPrimVal x) (NPrimVal y) 
        = if x == y 
             then pure [] 
             else convertError loc env (PrimVal x) (PrimVal y)
    unifyD _ _ mode loc env (NApp fx ax) (NApp fy ay)
        = unifyBothApps mode loc env fx ax fy ay
    unifyD _ _ mode loc env (NApp hd args) y 
        = unifyApp mode loc env hd args y
    unifyD _ _ mode loc env y (NApp hd args)
        = unifyApp mode loc env hd args y
    unifyD _ _ mode loc env x NErased = pure []
    unifyD _ _ mode loc env NErased y = pure []
    unifyD _ _ mode loc env NType NType = pure []
    unifyD _ _ mode loc env x y 
        = do gam <- get Ctxt
             log 10 $ "Conversion check: " ++ show (quote (noGam gam) env x) 
                                ++ " and " ++ show (quote (noGam gam) env y)
             unifyIfEq False loc env x y

  export
  Unify Term where
    -- TODO: Don't just go to values, try to unify the terms directly
    -- and avoid normalisation as far as possible
    unifyD _ _ mode loc env x y 
          = do gam <- get Ctxt
               unify mode loc env (nf gam env x) (nf gam env y)

-- Try again to solve the given named constraint, and return the list
-- of constraint names are generated when trying to solve it.
export
retry : {auto c : Ref Ctxt Defs} ->
        {auto u : Ref UST (UState annot)} ->
        UnifyMode -> (cname : Name) -> 
        Core annot (List Name)
retry mode cname
    = do ust <- get UST
         gam <- get Ctxt
         case lookupCtxtExact cname (constraints ust) of
              Nothing => pure []
              -- If the constraint is now resolved (i.e. unifying now leads
              -- to no new constraints) replace it with 'Resolved' in the
              -- constraint context so we don't do it again
              Just Resolved => pure []
              Just (MkConstraint loc env x y) =>
                   do log 5 $ "Retrying " ++ show (normalise gam env x)
                                          ++ " and " ++ show (normalise gam env y)
                      cs <- unify mode loc env x y
                      case cs of
                           [] => do log 5 "Success!"
                                    setConstraint cname Resolved
                                    pure []
                           _ => pure cs
              Just (MkSeqConstraint loc env xs ys) =>
                   do cs <- unifyArgs mode loc env xs ys
                      case cs of
                           [] => do setConstraint cname Resolved
                                    pure []
                           _ => pure cs

rerunDelayed : {auto c : Ref Ctxt Defs} ->
               {auto u : Ref UST (UState annot)} ->
               (hole : Name) -> (cname : Name) ->
               Core annot ()
rerunDelayed hole cname
    = do ust <- get UST
         case lookupCtxtExact cname (delayedElab ust) of
              Nothing => throw (InternalError ("No such delayed elaborator" ++ show cname))
              Just elab => 
                   do tm <- elab
                      updateDef hole (PMDef True [] (STerm tm))
                      removeHoleName hole

retryHole : {auto c : Ref Ctxt Defs} ->
            {auto u : Ref UST (UState annot)} ->
            UnifyMode -> (lastChance : Bool) -> (hole : (annot, Name)) ->
            Core annot ()
retryHole mode lastChance (loc, hole)
    = do gam <- get Ctxt
         case lookupDefExact hole (gamma gam) of
              Nothing => pure ()
              Just (Guess tm constraints) => 
                   do cs' <- traverse (\x => retry mode x) constraints
                      case concat cs' of
                           -- All constraints resolved, so turn into a
                           -- proper definition and remove it from the
                           -- hole list
                           [] => do updateDef hole (PMDef True [] (STerm tm))
                                    removeHoleName hole
                           newcs => updateDef hole (Guess tm newcs)
              Just (BySearch depth fn) => 
                   if lastChance
                      then do search loc depth [] fn hole; pure ()
                      else try (do search loc depth [] fn hole
                                   pure ())
                       (pure ()) -- postpone again
              Just _ => pure () -- Nothing we can do

retryDelayed : {auto c : Ref Ctxt Defs} ->
               {auto u : Ref UST (UState annot)} ->
               (lastChance : Bool) -> (hole : (annot, Name)) ->
               Core annot Bool
retryDelayed lastChance (loc, hole)
    = do gam <- get Ctxt
         case lookupDefExact hole (gamma gam) of
              Nothing => pure False
              Just (Delayed c) =>
                   if lastChance
                      then do rerunDelayed hole c
                              pure True
                      else try (do rerunDelayed hole c
                                   pure True)
                               (pure False)
              Just _ => pure False -- Nothing we can do

-- Attempt to solve any remaining constraints in the unification context.
-- Do this by working through the list of holes
-- On encountering a 'Guess', try the constraints attached to it 
export
solveConstraints : {auto c : Ref Ctxt Defs} ->
                   {auto u : Ref UST (UState annot)} ->
                   UnifyMode -> (lastChance : Bool) -> Core annot ()
solveConstraints mode lastChance
    = do hs <- getHoleInfo
         traverse (retryHole mode lastChance) hs
         -- Question: Another iteration if any holes have been resolved?
         pure ()

export
retryAllDelayed : {auto c : Ref Ctxt Defs} ->
                  {auto u : Ref UST (UState annot)} ->
                  Core annot ()
retryAllDelayed
    = do hs <- getHoleInfo
         case hs of
              [] => pure ()
              _ => do results <- traverse (retryDelayed False) hs
                   -- if we made any progress, go around again
                   -- Assumption is that this terminates because the set
                   -- of holes 'hs' will be smaller next time around, as
                   -- a successful result removes a hole
                      if or (map Delay results)
                         then retryAllDelayed
                         -- Otherwise one more go just to get the error
                         -- message
                         else do traverse (retryDelayed True) hs
                                 pure ()

export
checkDots : {auto u : Ref UST (UState annot)} ->
            {auto c : Ref Ctxt Defs} ->
            Core annot ()
checkDots
    = do ust <- get UST
         gam <- get Ctxt
         traverse (checkConstraint gam) (dotConstraints ust)
         put UST (record { dotConstraints = [] } ust)
         pure ()
  where
    checkConstraint : Defs -> (Name, Constraint annot) -> Core annot ()
    checkConstraint gam (n, MkConstraint loc env x y)
        = do cs <- unify InLHS loc env x y
             if isNil cs && not (isHoleNF (gamma gam) n)
                then pure ()
                else throw (BadDotPattern loc x y)
    checkConstraint gam _ = pure ()

