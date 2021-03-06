
function recursiveCycle(param::MGparam,b::ArrayTypes,x::ArrayTypes,level::Int64)

# println(string("Starting level ", level));

gmresTol = 1e-5;

n = size(b,1);
nrhs = size(b,2);
numCores = param.numCores;
As = param.As;
nlevels = length(As);


if level==nlevels # This actually does not need to happen unless one level only is used (i.e. exact solver).
	x = solveCoarsest(param,b,x);
	return x;
end

Ps = param.Ps;
Rs = param.Rs;
AT = As[level];

const oneType = one(eltype(b));
const zeroType = zero(eltype(b));
r = param.memCycle[level].r;

r[:] = b;
if vecnorm(x)>0.0	
   	SpMatMul(-oneType,AT,x,oneType,r,numCores)#  r -= A'*x;
end
D = param.relaxPrecs[level];
MM = identity;
Afun = identity;
if param.relaxType=="Jac-GMRES"
	y = param.memRelax[level].v_prec;
	MM(xx::ArrayTypes) = (SpMatMul(D,xx,y,numCores);return y;);
end

PT = Ps[level];
RT = Rs[level];

npresmth  = param.relaxPre(level);
npostsmth = param.relaxPost(level);

if param.relaxType=="Jac-GMRES"
    Afun = getAfun(AT,param.memRelax[level].Az,numCores)
	if nrhs == 1
		x = FGMRES_relaxation(Afun,r,x,npresmth,MM,gmresTol,false,true,numCores,param.memRelax[level])[1];
		# x = FGMRES(Afun,r,x,npresmth,MM,gmresTol,false,true,numCores,param.memRelax[level])[1];
	else
		for ii = 1:nrhs
			x[:,ii] = FGMRES_relaxation(Afun,r[:,ii],x[:,ii],npresmth,MM,gmresTol,false,true,numCores,param.memRelax[level])[1];
		end
		# x = BlockFGMRES(Afun,r,x,npresmth,MM,gmresTol,false,false,numCores, param.memRelax[level])[1];
		# x = BlockFGMRES_relaxation(AT,r,x,npresmth,MM,gmresTol,false,false,numCores, param.memRelax[level])[1];
	end
elseif param.relaxType == "VankaFaces"
	x = RelaxVankaFacesColor(AT,x,b,r,D,npresmth,numCores,param.Meshes[level],param.transferOperatorType=="SystemsFacesMixedLinear");
else
	x = relax(AT,r,x,b,D,npresmth,numCores);
end

SpMatMul(-oneType,AT,x,zeroType,r,numCores); #  r = -A'*x;
addVectors(oneType,b,r); # r = r + b;

xc = param.memCycle[level+1].x;
xc[:] = 0.0;
bc = param.memCycle[level+1].b;
bc = SpMatMul(RT,r,bc,numCores); 
if level==nlevels-1
	# println("solving coarsest");
	xc = solveCoarsest(param,bc,xc);
else
	Ac = As[level+1];
    if param.cycleType == 'K'
		yzK = param.memKcycle[level].v_prec;
		AfunK = getAfun(Ac,param.memKcycle[level].Az,numCores);
		MMG(x) = (yzK[:] = 0.0; recursiveCycle(param,x,yzK,level+1)); # x does not change...
		if nrhs==1
			xc = FGMRES_relaxation(AfunK,bc,xc,2,MMG,gmresTol,false,true,numCores,param.memKcycle[level])[1];
			# xc = FGMRES(AfunK,bc,xc,2,MMG,gmresTol,false,true,numCores,param.memKcycle[level])[1];
		else
			# xc = BlockFGMRES_relaxation(Ac,bc,xc,2,MMG,gmresTol,false,true,numCores,param.memKcycle[level+1])[1];
			xc = BlockFGMRES(AfunK,bc,xc,2,MMG,gmresTol,false,true,numCores,param.memKcycle[level])[1];
		end
    else
		xc = recursiveCycle(param,bc,xc,level+1);# xc changes, bc does not change
		if param.cycleType=='W'
            xc = recursiveCycle(param,bc,xc,level+1);
		elseif param.cycleType=='F'
            param.cycleType='V';
            xc = recursiveCycle(param,bc,xc,level+1);
			param.cycleType='F';
        end
    end
end


# Base.A_mul_B!(oneType,P,xc,oneType,x); # x += P*xc;

x = SpMatMul(oneType,PT,xc,oneType,x,numCores); # x += PT'*xc;

r[:] = b;
SpMatMul(-oneType,AT,x,oneType,r,numCores); #  r -= A'*x;
if param.relaxType=="Jac-GMRES"
	Afun = getAfun(AT,param.memRelax[level].Az,numCores)
	if nrhs == 1
		x = FGMRES_relaxation(Afun,r,x,npostsmth,MM,gmresTol,false,true,numCores,param.memRelax[level])[1];
		# x = FGMRES(Afun,r,x,npostsmth,MM,gmresTol,false,true,numCores,param.memRelax[level])[1];
	else
		for ii=1:nrhs
			x[:,ii] = FGMRES_relaxation(Afun,r[:,ii],x[:,ii],npostsmth,MM,gmresTol,false,true,numCores,param.memRelax[level])[1];
		end
		# x = BlockFGMRES(Afun,r,x,npostsmth,MM,gmresTol,false,false,numCores, param.memRelax[level])[1];
		# x = BlockFGMRES_relaxation(AT,r,x,npostsmth,MM,gmresTol,false,false,numCores, param.memRelax[level])[1];
	end
elseif param.relaxType == "VankaFaces"
	x = RelaxVankaFacesColor(AT,x,b,r,D,npostsmth,numCores,param.Meshes[level],param.transferOperatorType=="SystemsFacesMixedLinear");
else
	x = relax(AT,r,x,b,D,npostsmth,numCores);
end

return x
end



function relax(AT::SparseMatrixCSC,r::ArrayTypes,x::ArrayTypes,b::ArrayTypes,D::SparseMatrixCSC,numit::Int64,numCores::Int64)
# x is actually the output... x and is being changed in the iterations.
# r does not end up accurate becasue we do not update it in the last iteration.
const oneType = one(eltype(r));
const zeroType = zero(eltype(r));
# nr0 = vecnorm(r);
# println(nr0)
for i=1:numit-1	
	SpMatMul(oneType,D,r,oneType,x,numCores); # x = x + D'*r
	SpMatMul(-oneType,AT,x,zeroType,r,numCores) # r = -A'*x
	addVectors(oneType,b,r); # r = r + b;
	# println("Reduced: ", vecnorm(r)/nr0)
end
SpMatMul(oneType,D,r,oneType,x,numCores); # x = x + D'*r
return x
end


function solveCoarsest(param::MGparam,b::ArrayTypes,x::ArrayTypes,doTranspose::Int64=0)
if param.coarseSolveType == "MUMPS"
	applyMUMPS(param.LU,b,x,param.doTranspose);
elseif param.coarseSolveType == "BiCGSTAB"
	AT = param.As[end];
	maxIter = 100;
	tol = 0.1;
	out= -2;
	Afun = getAfun(AT,zeros(eltype(b),size(b)),param.numCores);
	D = param.LU;
	y = zeros(eltype(b),size(b));
	M1(xx::ArrayTypes) = (SpMatMul(D,xx,y,param.numCores);return y;);
	if size(b,2)==1
		b = vec(b);
		x, flag,rnorm,iter = KrylovMethods.bicgstb(Afun,b,tol = tol,maxIter = maxIter,M1 = M1,M2 = identity,out=out);
	else
		x, flag,rnorm,iter = KrylovMethods.blockBiCGSTB(Afun,b,tol = tol,maxIter = maxIter,M1 = M1,M2 = identity,out=out);
	end
	# println("Applied ",iter," BiCGSTAB");
elseif param.coarseSolveType == "GMRES"
	AT = param.As[end];
	maxIter = 1;
	tol = 0.01;
	out= -2;
	Afun = getAfun(AT,zeros(eltype(b),size(b)),param.numCores);
	D = param.LU;
	y = zeros(eltype(b),size(b));
	M2(xx::ArrayTypes) = (SpMatMul(D,xx,y,param.numCores);return y;);
	if size(b,2)==1
		b = vec(b);
		# x, flag,rnorm,iter = KrylovMethods.gmres(Afun,b,40,tol = tol,maxIter = maxIter,M = M2,out=out);
		x[:] = 0.0;
		(x,) = FGMRES(Afun,b,x,10,M2,tol,false,false,param.numCores);
	else
		error("Multiple RHS not supported");
	end
else
	x = param.LU\b;
end
return x;
end








