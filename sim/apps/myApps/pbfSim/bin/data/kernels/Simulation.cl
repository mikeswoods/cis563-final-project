/*******************************************************************************
 * UpdatePositions.cl
 * - The OpenCL kernel responsible for apply external forces, like gravity
 *   for instance to each particle in the simulation, and subsequenly updating
 *   the predicted position of each particle using a simple explicit Euler
 *   step
 *
 * CIS563: Physically Based Animation final project
 * Created by Michael Woods & Michael O'Meara
 ******************************************************************************/

/*******************************************************************************
 * Preprocessor directives
 ******************************************************************************/

#define NEIGHBOR_SEARCH_RADIUS 3
//#define NEIGHBOR_SEARCH_RADIUS 5

#define TOTAL_NEIGHBORS ((NEIGHBOR_SEARCH_RADIUS)*(NEIGHBOR_SEARCH_RADIUS)*(NEIGHBOR_SEARCH_RADIUS))

#if NEIGHBOR_SEARCH_RADIUS == 3
    const constant int searchOffsets[NEIGHBOR_SEARCH_RADIUS] = { -1, 0, 1 };
#elif NEIGHBOR_SEARCH_RADIUS == 5
    const constant int searchOffsets[NEIGHBOR_SEARCH_RADIUS] = { -2, -1, 0, 1, 2 };
#else
    #error "Neighbor search radius must be 3 or 5!"
#endif

/*******************************************************************************
 * Constants
 ******************************************************************************/

/**
 * A small epislon value
 */
const constant float EPSILON = 1.0e-4f;

/**
 * Acceleration force due to gravity: 9.8 m/s
 */
const constant float G = 9.8f;

/**
 * Particle rest density: 1000kg/m^3 = 10,000g/m^3
 */
const constant float REST_DENSITY     = 10000.0f;
const constant float INV_REST_DENSITY = 1.0f / REST_DENSITY;

/*******************************************************************************
 * Types
 ******************************************************************************/

// Tuneable parameters for the simulation:

typedef struct {
    
    float particleRadius;      // 1. Particle radius

    float smoothingRadius;     // 2. Kernel smoothing radius
    
    float relaxation;          // 3. Pressure relaxation coefficient (epsilon)
    
    float artificialPressureK; // 4. Artificial pressure coefficient K
    
    float artificialPressureN; // 5. Artificial pressure coefficient N
    
    float vorticityEpsilon;    // 6. Vorticity coefficient
    
    float viscosityCoeff;      // 7. Viscosity coefficient
    
    float __padding[1];
    
} Parameters;

// A particle type:

typedef struct {
    
    float4 pos;     // Current particle position (x), 4 words
    
    float4 posStar; // Predicted particle position (x*), 4 words
    
    float4 vel;     // Current particle velocity (v), 4 words

    /**
     * VERY IMPORTANT: This is needed so that the struct's size is aligned
     * for x86 memory access along 4/word 16 byte intervals.
     *
     * If the size is not aligned, results WILL be screwed up!!!
     * Don't be like me and waste hours trying to debug this issue. The
     * OpenCL compiler WILL NOT pad your struct to so that boundary aligned
     * like g++/clang will in host (C++) land!!!.
     *
     * See http://en.wikipedia.org/wiki/Data_structure_alignment
     */
    //float4  __padding[1]; // 1 words

} Particle;

// A type to represent the position of a given particle in the spatial
// grid the simulated world is divided into

typedef struct {

    int particleIndex; // Index of particle in particle buffer (1 word)

    int cellI;         // Corresponding grid index in the x-axis (1 word)
    
    int cellJ;         // Corresponding grid index in the y-axis (1 word)
    
    int cellK;         // Corresponding grid index in the z-axis (1 word)

    int key;           // Linearized index key computed from the subscript
                       // (cellI, cellJ, cellK)
    int __padding[3];
    
} ParticlePosition;

// A type that encodes the start and length of a grid cell in sortedParticleToCell

typedef struct {
    
    int  start; // Start of the grid cell in sortedParticleToCell
    
    int length;
    
    int __padding[2]; // Padding
    
} GridCellOffset;

/*******************************************************************************
 * Forward declarations
 ******************************************************************************/

float rescale(float x, float a0, float a1, float b0, float b1);

int sub2ind(int i, int j, int k, int w, int h);

int3 ind2sub(int x, int w, int h);

int getKey(const global Particle* p
          ,int cellsX
          ,int cellsY
          ,int cellsZ
          ,float3 minExtent
          ,float3 maxExtent);

int3 getSubscript(const global Particle* p
                 ,int cellsX
                 ,int cellsY
                 ,int cellsZ
                 ,float3 minExtent
                 ,float3 maxExtent);

void clampToBounds(const global Parameters* parameters
                  ,global Particle* p
                  ,float3 minExtent
                  ,float3 maxExtent);

float poly6(float4 r, float h);

float4 spiky(float4 r, float h);

void callback_SPHDensityEstimator_i(const global Parameters* parameters
                                   ,int i
                                   ,const global Particle* p_i
                                   ,int j
                                   ,const global Particle* p_j
                                   ,void* dataArray
                                   ,void* accum);

void callback_SPHGradient_i(const global Parameters* parameters
                           ,int i
                           ,const global Particle* p_i
                           ,int j
                           ,const global Particle* p_j
                           ,void* dataArray
                           ,void* accum);

void callback_SquaredSPHGradientLength_j(const global Parameters* parameters
                                        ,int i
                                        ,const global Particle* p_i
                                        ,int j
                                        ,const global Particle* p_j
                                        ,void* dataArray
                                        ,void* accum);

 void callback_PositionDelta_i(const global Parameters* parameters
                              ,int i
                              ,const global Particle* p_i
                              ,int j
                              ,const global Particle* p_j
                              ,void* dataArray
                              ,void* accum);

void callback_Curl_i(const global Parameters* parameters
                    ,int i
                    ,const global Particle* p_i
                    ,int j
                    ,const global Particle* p_j
                    ,void* dataArray
                    ,void* accum);

void callback_Vorticity_i(const global Parameters* parameters
                         ,int i
                         ,const global Particle* p_i
                         ,int j
                         ,const global Particle* p_j
                         ,void* dataArray
                         ,void* accum);

void callback_XPSHViscosity_i(const global Parameters* parameters
                             ,int i
                             ,const global Particle* p_i
                             ,int j
                             ,const global Particle* p_j
                             ,void* dataArray
                             ,void* accum);

int getNeighboringCells(const global ParticlePosition* sortedParticleToCell
                       ,const global GridCellOffset* gridCellOffsets
                       ,int cellsX
                       ,int cellsY
                       ,int cellsZ
                       ,int3 cellSubscript
                       ,int* neighborCells);

void forAllNeighbors(const global Parameters* parameters
                    ,const global Particle* particles
                    ,const global ParticlePosition* sortedParticleToCell
                    ,const global GridCellOffset* gridCellOffsets
                    ,int numParticles
                    ,int cellsX
                    ,int cellsY
                    ,int cellsZ
                    ,float3 minExtent
                    ,float3 maxExtent
                    ,int particleId
                    ,float searchRadius
                    ,void* dataArray
                    ,void (*callback)(const global Parameters*
                                     ,int
                                     ,const global Particle*
                                     ,int
                                     ,const global Particle*
                                     ,void* dataArray
                                     ,void* currentAccum)
                    ,void* initialAccum);

/*******************************************************************************
 * Utility functions
 ******************************************************************************/

/**
 * A helper function that scales a value x in the range [a0,a1] to a new
 * range [b0,b1]
 */
float rescale(float x, float a0, float a1, float b0, float b1)
{
    return ((x - a0) / (a1 - a0)) * (b1 - b0) + b0;
}

/**
 * A function that converts a 3D subscript (i,j,k) into a linear index
 *
 * @param [in] int i x component of subscript
 * @param [in] int j y component of subscript
 * @param [in] int k z component of subscript
 * @param [in] int w grid width
 * @param [in] int h grid height
 */
int sub2ind(int i, int j, int k, int w, int h)
{
    return i + (j * w) + k * (w * h);
}

/**
 * A function that converts a linear index x into a 3D subscript (i,j,k)
 *
 * @param [in] int x The linear index x
 * @param [in] int w grid width
 * @param [in] int h grid height
 */
int3 ind2sub(int x, int w, int h)
{
    return (int3)(x % w, (x / w) % h, x / (w * h));
}

/**
 * Given a Particle, this function returns the 3D cell subscript of the cell the
 * particle is contained in
 *
 * @param Particle* p The particle to find the cell key of
 * @param [in] int cellsX The number of cells in the x axis of the spatial
 *             grid
 * @param [in] int cellsY The number of cells in the y axis of the spatial
 *             grid
 * @param [in] int cellsZ The number of cells in the z axis of the spatial
 *             grid
 * @param [in] float3 minExtent The minimum extent of the simulation's
 *             bounding box in world space
 * @param [in] float3 maxExtent The maximum extent of the simulation's
 *             bounding box in world space
 * @returns int3 The 3D subscript (i,j,k) of the cell the particle is
 *               contained in
 */
int3 getSubscript(const global Particle* p
                       ,int cellsX
                       ,int cellsY
                       ,int cellsZ
                       ,float3 minExtent
                       ,float3 maxExtent)
{
    // Find the discretized cell the particle will be in according to its
    // predicted position:
    int i = (int)round((rescale(p->posStar.x, minExtent.x, maxExtent.x, 0.0f, (float)(cellsX - 1))));
    int j = (int)round((rescale(p->posStar.y, minExtent.y, maxExtent.y, 0.0f, (float)(cellsY - 1))));
    int k = (int)round((rescale(p->posStar.z, minExtent.z, maxExtent.z, 0.0f, (float)(cellsZ - 1))));
    
    return (int3)(i, j, k);
}

/**
 * Given a Particle, this function returns 1D cell index of the cell the 
 * particle is contained in
 *
 * @param Particle* p The particle to find the cell key of
 * @param [in] int cellsX The number of cells in the x axis of the spatial
 *             grid
 * @param [in] int cellsY The number of cells in the y axis of the spatial
 *             grid
 * @param [in] int cellsZ The number of cells in the z axis of the spatial
 *             grid
 * @param [in] float3 minExtent The minimum extent of the simulation's
 *             bounding box in world space
 * @param [in] float3 maxExtent The maximum extent of the simulation's
 *             bounding box in world space
 * @returns int The 1D key of the cell the particle is contained in
 */
int getKey(const global Particle* p
                 ,int cellsX
                 ,int cellsY
                 ,int cellsZ
                 ,float3 minExtent
                 ,float3 maxExtent)
{
    int3 subscript = getSubscript(p, cellsX, cellsY, cellsZ, minExtent, maxExtent);

    // Compute the linear index as the key:
    return sub2ind(subscript.x, subscript.y, subscript.z, cellsX, cellsY);
}

/**
 * Given a particle, p, this function will clamp the particle's position to
 * the region defining the valid boundary of the simulation
 *
 * @param [in]     Parameters* parameters The runtime parameters of the 
 *                 simulation
 * @param [in/out] Parameters* parameters The particle to clamp
 * @param [in]     float3 minExtent The minimum extent of the simulation's
 *                 bounding box in world space
 * @param [in]     float3 maxExtent The maximum extent of the simulation's
 *                 bounding box in world space
 */
void clampToBounds(const global Parameters* parameters
                  ,global Particle* p
                  ,float3 minExtent
                  ,float3 maxExtent)
{
    // Clamp predicted and actual positions:
    
    float R = parameters->particleRadius;
    
    // Clamp the predicted positions to the bounding box of the simulation:
    
    p->posStar.x = clamp(p->posStar.x, minExtent.x + R, maxExtent.x - R);
    p->posStar.y = clamp(p->posStar.y, minExtent.y + R, maxExtent.y - R);
    p->posStar.z = clamp(p->posStar.z, minExtent.z + R, maxExtent.z - R);
}

/**
 * Given the subscript (i,j,k) as an int3 of a cell to search the vicinity of,
 * this function will return a count of valid neighboring cells (including
 * itself) in the range [1,TOTAL_NEIGHBORS], e.g. between 1 and TOTAL_NEIGHBORS 
 * neighboring cells are valid and need to be searched for neighbors. 
 * The indices from [0 .. TOTAL_NEIGHBORS-1] will be populated with the indices 
 * of neighboring cells in gridCellOffsets, such that for each neighboring grid 
 * cell (i', j', k'), 0 <= i' < cellX, 0 <= j' < cellY, 0 <= k' < cellZ, and the
 * corresponding entry for cell (i',j',k') in gridCellOffsets has a cell 
 * start index != -1.
 *
 * @param [in]  ParticlePosition* sortedParticleToCell
 * @param [in]  GridCellOffset* gridCellOffsets
 * @param [in]  int cellsX The number of cells in the x axis of the spatial
 *              grid
 * @param [in]  int cellsY The number of cells in the y axis of the spatial
 *              grid
 * @param [in]  int cellsZ The number of cells in the z axis of the spatial
 *              grid
 * @param [in]  int3 cellSubscript
 * @param [out] int* neighborCells
 */
int getNeighboringCells(const global ParticlePosition* sortedParticleToCell
                       ,const global GridCellOffset* gridCellOffsets
                       ,int cellsX
                       ,int cellsY
                       ,int cellsZ
                       ,int3 cellSubscript
                       ,int* neighborCells)
{
    // Count of valid neighbors:

    int neighborCellCount = 0;

    int I, J, K;
    
    // -1 indicates an invalid/non-existent neighbor:

    for (int i = 0; i < TOTAL_NEIGHBORS; i++) {
        neighborCells[i] = -1;
    }

    I = J = K = -1;
    
    // We need to search the following potential TOTAL_NEIGHBORS cells about
    // the position (i,j,k):
    
    for (int u = 0; u < NEIGHBOR_SEARCH_RADIUS; u++) {

        I = cellSubscript.x + searchOffsets[u]; // I = i-1, i, i+1

        for (int v = 0; v < NEIGHBOR_SEARCH_RADIUS; v++) {
        
            J = cellSubscript.y + searchOffsets[v]; // J = j-1, j, j+1

            for (int w = 0; w < NEIGHBOR_SEARCH_RADIUS; w++) {
            
                K = cellSubscript.z + searchOffsets[w]; // K = k-1, k, k+1
                
                if (   (I >= 0 && I < cellsX)
                    && (J >= 0 && J < cellsY)
                    && (K >= 0 && K < cellsZ))
                {
                    int key = sub2ind(I, J, K, cellsX, cellsY);

                    // The specified grid cell offset has a valid starting
                    // index, so we can return it as a valid neighbor:

                    if (gridCellOffsets[key].start != -1) {
                        neighborCells[neighborCellCount++] = key;
                    }
                }
            }
        }
    }
    
    return neighborCellCount;
}

/**
 * For all neighbors p_j of a particle p_i, this function will apply the given
 * function to all particle pairs (p_i, p_j), accumulating the result and
 * returning it
 *
 * @param [in]  Parameters* parameters The runtime parameters of the simulation
 * @param [in]  Particle* particles Particles in the simulation
 * @param [in]  ParticlePosition* sortedParticleToCell A mapping of particles
 *              to cells. sortedParticleToCell
 * @param [in]  GridCellOffset* gridCellOffsets
 * @param [in]  int numParticles The total number of particles in the simulation
 * @param [in]  int cellsX The number of cells in the x axis of the spatial
 *              grid
 * @param [in]  int cellsY The number of cells in the y axis of the spatial
 *              grid
 * @param [in]  int cellsZ The number of cells in the z axis of the spatial
 *              grid
 * @param [in]  float3 minExtent The minimum extent of the simulation's
 *              bounding box in world space
 * @param [in]  float3 maxExtent The maximum extent of the simulation's
 *              bounding box in world space
 * @param [in]  int particleId The ID (index) of the particle to find the n
 *              neighbors of. This value corresponds to the position of the 
 *              particle in the array particles, and must be in the range
 *              [0 .. numParticles - 1]
 * @param [in]  float searchRadius The search radius
 * param  [in]  void* dataArray A read-only auxiliary data array to pass to
 *              invoked callback functions
 * @param [in]  (*callback)(int, const global Particle*, int, const global Particle*, void* accum)
 * @param [out] void* accum The accumulated result, passed to and update by apply
 *              for every neighbor pair of particles
 */
void forAllNeighbors(const global Parameters* parameters
                    ,const global Particle* particles
                    ,const global ParticlePosition* sortedParticleToCell
                    ,const global GridCellOffset* gridCellOffsets
                    ,int numParticles
                    ,int cellsX
                    ,int cellsY
                    ,int cellsZ
                    ,float3 minExtent
                    ,float3 maxExtent
                    ,int particleId
                    ,float searchRadius
                    ,void* dataArray
                    ,void (*callback)(const global Parameters*
                                     ,int
                                     ,const global Particle*
                                     ,int
                                     ,const global Particle*
                                     ,void* dataArray
                                     ,void* currentAccum)
                    ,void* initialAccum)
{
    // Sanity check:
    if (particleId < 0 || particleId >= numParticles) {
        return;
    }

    const global Particle *p_i = &particles[particleId];

    // Given a particle, find the cell it's in based on its position:

    int3 cellSubscript = getSubscript(p_i, cellsX, cellsY, cellsZ, minExtent, maxExtent);

    // TOTAL_NEIGHBORS = NEIGHBOR_SEARCH_RADIUS^3 possible neighbors to search:

    int neighborCells[TOTAL_NEIGHBORS];
    int neighborCellCount = getNeighboringCells(sortedParticleToCell
                                               ,gridCellOffsets
                                               ,cellsX
                                               ,cellsY
                                               ,cellsZ
                                               ,cellSubscript
                                               ,neighborCells);
    
    // For all neighbors found for the given cell at grid subscript (i,j,k):

    for (int j = 0; j < neighborCellCount; j++) {
        
        // We fetch the all indices returned in neighbors and check that
        // the corresponding entries in gridCellOffsets (if neighbors[j]
        // is valid):
        
        if (neighborCells[j] == -1) {
            continue;
        }
            
        const global GridCellOffset* g = &gridCellOffsets[neighborCells[j]];
            
        // If the start index of the grid-cell is valid, we iterate over
        // every particle we find in the cell:
            
        if (g->start == -1) {
            continue;
        }
                
        int start = g->start;
        int end   = start + g->length;
        
        for (int k = start; k < end; k++) {
            
            int J = sortedParticleToCell[k].particleIndex;
            
            // Skip instances in which we'd be comparing a particle to itself:
            
            if (particleId == J) {
                continue;
            }
            
            // The current potentially neighboring particle to check
            // the distance of:
            
            const global Particle* p_j = &particles[J];
            
            // To determine if p_j is actually a neighbor of p_i, we
            // test if the position delta is less then the sum of the
            // radii of both particles. If p_j is a neighbor of p_i,
            // we invoke the specified callback and accumulate the
            // result:

            float d = distance(p_i->posStar, p_j->posStar);
            float R = parameters->particleRadius + searchRadius;
            
            if ((d - R) <= 0.0f) {

                // Invoke the callback function to the particle pair
                // (p_i, p_j), along with their respective indices,
                // and accumulate the result into accum:

                callback(parameters, particleId, p_i, J, p_j, dataArray, initialAccum);
            }
        }
    }
}

/*******************************************************************************
 * Density estimation functions
 ******************************************************************************/

/**
 * Computed the poly6 scalar smoothing kernel
 *
 * From the PBF slides SIGGRAPH 2013, pg. 13
 *
 * @param [in] float4 r distance
 * @param [in] float h Smoothing kernel radius
 * @returns float The computed scalar value
 */
float poly6(float4 r, float h)
{
    float rBar = length(r);

    if (rBar < EPSILON || rBar > h) {
        return 0.0f;
    }
    
    // (315 / (64 * PI * h^9)) * (h^2 - |r|^2)^3
    float h9 = (h * h * h * h * h * h * h * h * h);
    if (h9 < EPSILON) {
        return 0.0f;
    }
    float A  = 1.566681471061f / h9;
    float B  = (h * h) - (rBar * rBar);

    return A * (B * B * B);
}

/**
 * Computes the spiky smoothing kernel gradient
 *
 * From the PBF slides SIGGRAPH 2013, pg. 13
 *
 * @param [in] float4 r distance
 * @param [in] float h Smoothing kernel radius
 * @returns float4 The computed gradient in (x,y,z,w)
 */
float4 spiky(float4 r, float h)
{
    float rBar = length(r);

    if (rBar < EPSILON || rBar > h) {
        return (float4)(0.0f, 0.0f, 0.0f, 0.0f);
    }

    // (45 / (PI * h^6)) * (h - |r|)^2 * (r / |r|)
    float h6   = (h * h * h * h * h * h);
    if (h6 < EPSILON) {
        return (float4)(0.0f, 0.0f, 0.0f, 0.0f);
    }
    float A    = 14.323944878271f / h6;
    float B    = (h - rBar);
    float4 out = A * (B * B) * (r / (rBar + EPSILON));
    out[3] = 0.0f;
    return out;
}

/**
 * SPH density estimator for a pair of particles p_i and p_j for use as a 
 * callback function with forAllNeighbors()
 *
 * @param [in] Parameters* parameters Simulation parameters
 * @param [in] int i The fixed index of particle i
 * @param [in] Particle* p_i The i-th (fixed) particle, particle p_i
 * @param [in] int j The varying index of particle j
 * @param [in] Particle* p_j The j-th (varying) particle, particle p_j
 * @param [in] void* dataArray An auxiliary readonly source data array to access
 * @param [in] void* accum An accumulator value to update
 */
void callback_SPHDensityEstimator_i(const global Parameters* parameters
                                   ,int i
                                   ,const global Particle* p_i
                                   ,int j
                                   ,const global Particle* p_j
                                   ,void* dataArray
                                   ,void* accum)
{
    // Cast the void pointer to the type we expect, so we can update the
    // variable accordingly:
    
    float* accumDensity = (float*)accum;

    (*accumDensity) += poly6(p_i->posStar - p_j->posStar, parameters->smoothingRadius);
}

/**
 * A callback function that computes the SPH gradient of a constraint 
 * function C_i, w.r.t a particle p_j for the case when i = j
 *
 * @param [in] Parameters* parameters Simulation parameters
 * @param [in] int i The fixed index of particle i
 * @param [in] Particle* p_i The i-th (fixed) particle, particle p_i
 * @param [in] int j The varying index of particle j
 * @param [in] Particle* p_j The j-th (varying) particle, particle p_j
 * @param [in] void* dataArray An auxiliary readonly source data array to access
 * @param [in] void* accum An accumulator value to update
 */
void callback_SPHGradient_i(const global Parameters* parameters
                           ,int i
                           ,const global Particle* p_i
                           ,int j
                           ,const global Particle* p_j
                           ,void* dataArray
                           ,void* accum)
{
    // Cast the void pointer to the type we expect, so we can update the
    // variable accordingly:

    float4* gradVector = (float4*)accum;

    (*gradVector) += spiky(p_i->posStar - p_j->posStar, parameters->smoothingRadius);
}

/**
 * A callback function that computes the squared length of the SPH gradient 
 * of a constraint function C_i, w.r.t a particle p_j for the case when i != j
 *
 * @param [in] Parameters* parameters Simulation parameters
 * @param [in] int i The fixed index of particle i
 * @param [in] Particle* p_i The i-th (fixed) particle, particle p_i
 * @param [in] int j The varying index of particle j
 * @param [in] Particle* p_j The j-th (varying) particle, particle p_j
 * @param [in] void* dataArray An auxiliary readonly source data array to access
 * @param [in] void* accum An accumulator value to update
 */
void callback_SquaredSPHGradientLength_j(const global Parameters* parameters
                                        ,int i
                                        ,const global Particle* p_i
                                        ,int j
                                        ,const global Particle* p_j
                                        ,void* dataArray
                                        ,void* accum)
{
    // Cast the void pointer to the type we expect, so we can update the
    // variable accordingly:
    
    float* totalGradLength = (float*)accum;

    float4 gradVector      = (INV_REST_DENSITY * -spiky(p_i->posStar - p_j->posStar, parameters->smoothingRadius));
    float gradVectorLength = length(gradVector);
    
    (*totalGradLength) += (gradVectorLength * gradVectorLength);
}

/**
 * A callback function that computes the position delta of a particle p_i 
 * given a neighbor particle p_j
 *
 * @param [in] Parameters* parameters Simulation parameters
 * @param [in] int i The fixed index of particle i
 * @param [in] Particle* p_i The i-th (fixed) particle, particle p_i
 * @param [in] int j The varying index of particle j
 * @param [in] Particle* p_j The j-th (varying) particle, particle p_j
 * @param [in] void* dataArray An auxiliary readonly source data array to access
 * @param [in] void* accum An accumulator value to update
 */
 void callback_PositionDelta_i(const global Parameters* parameters
                              ,int i
                              ,const global Particle* p_i
                              ,int j
                              ,const global Particle* p_j
                              ,void* dataArray
                              ,void* accum)
{
    // Cast the void pointer to the type we expect, so we can update the
    // variable accordingly:
    
    float* lambda    = (float*)dataArray;
    float4* posDelta = (float4*)accum;

    float lambda_i = lambda[i];
    float lambda_j = lambda[j];

    // Introduce the artificial pressure corrector:
    
    float h         = parameters->smoothingRadius;
    float4 r        = p_i->posStar - p_j->posStar;
    float4 gradient = spiky(r, h);
    float n         = poly6(r, h);
    
    // For the point delta Q, we use p_j->posStar as a starting point, and
    // add an offset value:

    float offset    = (0.3f * h);
    float4 deltaQ   = p_i->posStar + (float4)(offset, offset, offset, 1.0f);
    float d         = poly6(deltaQ, h);
    float nd        = fabs(d) <= EPSILON ? 0.0f : n / d;
    
    // Finally, compute the correction pressure:

    float s_corr = -parameters->artificialPressureK * pow(nd, parameters->artificialPressureN);

    (*posDelta) += ((lambda_i + lambda_j + s_corr) * gradient);
}

/**
 * A callback function that computes the curl force acting on a given
 * particle, p_i
 *
 * @param [in] Parameters* parameters Simulation parameters
 * @param [in] int i The fixed index of particle i
 * @param [in] Particle* p_i The i-th (fixed) particle, particle p_i
 * @param [in] int j The varying index of particle j
 * @param [in] Particle* p_j The j-th (varying) particle, particle p_j
 * @param [in] void* dataArray An auxiliary readonly source data array to access
 * @param [in] void* accum An accumulator value to update
 */
void callback_Curl_i(const global Parameters* parameters
                    ,int i
                    ,const global Particle* p_i
                    ,int j
                    ,const global Particle* p_j
                    ,void* dataArray
                    ,void* accum)
{
    float4* omega_i = (float4*)accum;

    float4 v_ij        = p_i->vel - p_j->vel;
    float4 gradient_ij = spiky(p_i->posStar - p_j->posStar, parameters->smoothingRadius);

    (*omega_i) += cross(v_ij, gradient_ij);
}

/**
 * A callback function that computes the vorticity force acting on a given
 * particle, p_i
 *
 * @param [in] Parameters* parameters Simulation parameters
 * @param [in] int i The fixed index of particle i
 * @param [in] Particle* p_i The i-th (fixed) particle, particle p_i
 * @param [in] int j The varying index of particle j
 * @param [in] Particle* p_j The j-th (varying) particle, particle p_j
 * @param [in] void* dataArray An auxiliary readonly source data array to access
 * @param [in] void* accum An accumulator value to update
 */
void callback_Vorticity_i(const global Parameters* parameters
                         ,int i
                         ,const global Particle* p_i
                         ,int j
                         ,const global Particle* p_j
                         ,void* dataArray
                         ,void* accum)
{
    float4* curl          = (float4*)dataArray;
    float4* omegaGradient = (float4*)accum;
    
    float4 r = p_i->posStar - p_j->posStar;
    float omegaBar = length(curl[i] - curl[j]);

    (*omegaGradient) += (float4)(omegaBar / r.x, omegaBar / r.y, omegaBar / r.z, 0.0f);
}

/**
 * A callback function that computes the XSPH viscosity acting on a given
 * particle, p_i
 *
 * @param [in] Parameters* parameters Simulation parameters
 * @param [in] int i The fixed index of particle i
 * @param [in] Particle* p_i The i-th (fixed) particle, particle p_i
 * @param [in] int j The varying index of particle j
 * @param [in] Particle* p_j The j-th (varying) particle, particle p_j
 * @param [in] void* dataArray An auxiliary readonly source data array to access
 * @param [in] void* accum An accumulator value to update
 */
void callback_XPSHViscosity_i(const global Parameters* parameters
                             ,int i
                             ,const global Particle* p_i
                             ,int j
                             ,const global Particle* p_j
                             ,void* dataArray
                             ,void* accum)
{
    float4* v_ij_sum = (float4*)accum;
    
    float4 v_ij = p_i->vel - p_j->vel;
    float W_ij  = poly6(p_i->posStar - p_j->posStar, parameters->smoothingRadius);
    
    (*v_ij_sum) += (W_ij * v_ij);
}

/*******************************************************************************
 * Kernels
 ******************************************************************************/

/**
 * A simple debugging kernel
 */
kernel void debugHistogram(global int* cellHistogram
                          ,global int* prefixSums
                          ,int numCells)
{
    for (int i = 0; i < numCells; i++) {
        printf("HISTOGRAM [%d] => %d, PREFIX-SUM[%d] => %d\n", i, cellHistogram[i], i, prefixSums[i]);
    }
}

/**
 * A simple debugging kernel
 */
kernel void debugSorting(global ParticlePosition* P2C
                        ,global ParticlePosition* sortedP2C
                        ,int numParticles)
{
    for (int i = 0; i < numParticles; i++) {
        printf("[%d] <particle=%d, key = %d>, SORTED: <particle=%d, key = %d>\n",
               i, P2C[i].particleIndex, P2C[i].key, sortedP2C[i].particleIndex, sortedP2C[i].key);
    }
}

/**
 * For all particles p_i in particles, this kernel resets all associated
 * quantities, like density, etc.
 */
kernel void resetParticleQuantities(global Particle* particles
                                   ,global ParticlePosition* particleToCell
                                   ,global ParticlePosition* sortedParticleToCell
                                   ,global float* density
                                   ,global float* lambda
                                   ,global float4* posDelta)
{
    int id = get_global_id(0);
    global Particle *p           = &particles[id];
    global ParticlePosition *pp  = &particleToCell[id];
    global ParticlePosition *spp = &sortedParticleToCell[id];

    // Particle index; -1 indicates unset
    pp->particleIndex = pp->cellI = pp->cellJ = pp->cellK = pp->key = -1;
    spp->particleIndex = spp->cellI = spp->cellJ = spp->cellK = spp->key = -1;

    p->posStar   = (float4)(0.0f, 0.0f, 0.0f, 0.0f);
    density[id]  = 0.0f;
    lambda[id]   = 0.0f;
    posDelta[id] = (float4)(0.0f, 0.0f, 0.0f, 0.0f);
}

/**
 * For all cells in the spatial grid, this kernel resets all associated 
 * quantities
 */
kernel void resetCellQuantities(global int* cellHistogram
                               ,global int* cellPrefixSums
                               ,global GridCellOffset* gridCellOffsets)
{
    int id = get_global_id(0);

    cellHistogram[id] = cellPrefixSums[id] = 0;

    gridCellOffsets[id].start  = -1;
    gridCellOffsets[id].length = -1;
}

/**
 * This kernel computes lines (1) - (4) of the PBF algorithm, as described
 * in the paper, specifically:
 *
 * (1) for all particles i do
 * (2)   apply forces     v_i  <- v_i + \delta t * f_ext(x_i)
 * (3)   predict position x*_i <- x_i + \delta t * v_i
 * (4) end for
 *
 * @param [in/out] Particle* particles The particles to update
 * @param [in/out] float4* extForces Accumulated external forces acting on
 *                 particle p_i
 * @param [in]     float dt The timestep
 */
kernel void predictPosition(global Particle* particles
                           ,global float4* extForces
                           ,float dt)
{
    int id = get_global_id(0);
    global Particle *p = &particles[id];
    
    // Add gravity to the accumulated force:

    p->vel.y += (dt * -G);

    // Apply an explicit Euler step on the particle's current position to
    // compute the predicted position, posStar (x*):

    p->posStar = p->pos + (dt * p->vel);
}

/**
 * For all particles p_i in particles, this kernel discretizes each p_i's
 * position into a grid of cells with dimensions specified by cellsPerAxis.
 *
 * @param [in] Particle* particles The particles to assign to cells
 * @param [out] int2* particleToCell Each entry contains a int2 pair
 * (i,j), where i is the particle in the i-th entry of particles, and j is
 * the linear index of the corresponding linear bin (j_x, j_y, j_z), where
 * 0 <= j_x < cellsPerAxis.x, 0 <= j_y < cellsPerAxis.y,
 * and 0 <= j_z < cellsPerAxis.z
 * @param [out] int* cellHistogram A histogram of counts of particles per cell
 * @param [in] int cellsX The number of cells in the x axis of the spatial
 *             grid
 * @param [in] int cellsY The number of cells in the y axis of the spatial
 *             grid
 * @param [in] int cellsZ The number of cells in the z axis of the spatial
 *             grid
 * @param [in] float3 minExtent The minimum extent of the simulation's
 *             bounding box in world space
 * @param [in] float3 maxExtent The maximum extent of the simulation's
 *             bounding box in world space
 */
kernel void discretizeParticlePositions(const global Particle* particles
                                       ,global ParticlePosition* particleToCell
                                       ,global int* cellHistogram
                                       ,int cellsX
                                       ,int cellsY
                                       ,int cellsZ
                                       ,float3 minExtent
                                       ,float3 maxExtent)
{
    int id                       = get_global_id(0);
    const global Particle *p     = &particles[id];
    global ParticlePosition *p2c = &particleToCell[id];
    
    // Convert the particle's position (x,y,z) to a grid cell subscript (i,j,k):
    int3 subscript = getSubscript(p, cellsX, cellsY, cellsZ, minExtent, maxExtent);
    
    // Convert the particle's position (x,y,z) to a linear index key:
    int key = getKey(p, cellsX, cellsY, cellsZ, minExtent, maxExtent);

    p2c->particleIndex = id;
    
    // Set the (i,j,k) index of the cell:

    p2c->cellI = subscript.x;
    p2c->cellJ = subscript.y;
    p2c->cellK = subscript.z;
    p2c->key   = key;

    // Next, we increment the count of particles contained in a given cell
    // in the spatial grid. Since multiple threads are modifying cellHistogram
    // simultaneously, need to ensure that we increment the count associated
    // with each cell is done atomically, hence we use the OpenCL atomic_add
    // primitive to increment the count.

    atomic_add(&cellHistogram[key], 1);
}

/**
 * Using the prefix sums generated from the cell histogram, we can sort the
 * particles by grid cell using a simple, easily parallelizable counting sort
 */
kernel void countSortParticlesByCell(global ParticlePosition* particleToCell
                                    ,global ParticlePosition* sortedParticleToCell
                                    ,global int* cellPrefixSums
                                    ,int numParticles)
{
    int id = get_global_id(0);
    global ParticlePosition* p2c = &particleToCell[id];

    // Again, due to the way OpenCL manages thread level parallelism, we need
    // to atomic_add and operate on the old, previous index value before the
    // increment op.
    // See http://stackoverflow.com/questions/18366359/opencl-kernel-incrementing-index-of-array
    // for details, specifically http://stackoverflow.com/a/18392827

    int prev = atomic_add(&cellPrefixSums[p2c->key], 1);

    sortedParticleToCell[prev] = *p2c;
}

/**
 * NOTE: This kernel is meant to be run with 1 thread. This is necessary
 * since we have to perform a sort and perform some other actions which are
 * inherently sequential in nature
 *
 * @see discretizeParticlePositions
 *
 * @param [out]    ParticlePosition* sortedParticleToCell
 * @param [out]    GridCellOffset* gridCellOffsets An array of size
 *                 [0 .. numCells-1], where each index i contains the start and
 *                 length of the i-th cell in the grid as it occurs in
 *                 sortedParticleToCell
 * @param [in] int numParticles The total number of particles in the simulation
 */
kernel void findParticleBins(global ParticlePosition* sortedParticleToCell
                            ,global GridCellOffset* gridCellOffsets
                            ,int numParticles)
{
    int id  = get_global_id(0);
    int key = sortedParticleToCell[id].key;
    
    if (gridCellOffsets[key].start == -1) {

        int left  = id;
        int right = id;
        
        while (left >= 0 && sortedParticleToCell[left].key == key) {
            left--;
        }
        
        while (right < numParticles && sortedParticleToCell[right].key == key) {
            right++;
        }
        
        left++;

        gridCellOffsets[key].start  = left;
        gridCellOffsets[key].length = right - left;
    }
}

/**
 * For all particles p_i in particles, this kernel computes the density
 * for p_i using SPH density estimation, as referenced in the PBF paper.
 *
 * Detail-wise, he SPH density estimator calculates 
 * 
 * \rho_i = \sum_j * m_j * W(p_i - p_j, h),
 *
 * where \rho_i is the density of the i-th particle, m_j is the mass of the 
 * j-th particle, p_i - p_j is the position delta between the particles p_i and
 * p_j and h is the smoothing radius
 *
 * The density for each particle p_i is a necessary prerequisite needed to
 * compute the \lambda value for each particle
 *
 * @param [in]  Parameters* parameters
 * @param [in]  Particle* particles
 * @param [in]  ParticlePosition* sortedParticleToCell
 * @param [in]  GridCellOffset* gridCellOffsets
 * @param [in]  int numParticles The number of particles in the simulation
 * @param [in]  int cellsX The number of cells in the x axis of the spatial
 *              grid
 * @param [in]  int cellsY The number of cells in the y axis of the spatial
 *              grid
 * @param [in]  int cellsZ The number of cells in the z axis of the spatial
 *              grid
 * @param [in]  float3 minExtent The minimum extent of the simulation's
 *              bounding box in world space
 * @param [in]  float3 maxExtent The maximum extent of the simulation's
 *              bounding box in world space
 * @param [out] float* density
 */
void kernel estimateDensity(const global Parameters* parameters
                           ,const global Particle* particles
                           ,const global ParticlePosition* sortedParticleToCell
                           ,const global GridCellOffset* gridCellOffsets
                           ,int numParticles
                           ,int cellsX
                           ,int cellsY
                           ,int cellsZ
                           ,float3 minExtent
                           ,float3 maxExtent
                           ,global float* density)
{
    int id = get_global_id(0);

    // For all neighboring particles p_j of the current particle (specified
    // by particles[id], aka p_i), apply the function estimateDensity for
    // all (p_i, p_j), accumulating the result into the density variable:

    float estDensity = 0.0f;
    
    forAllNeighbors(parameters
                   ,particles
                   ,sortedParticleToCell
                   ,gridCellOffsets
                   ,numParticles
                   ,cellsX
                   ,cellsY
                   ,cellsZ
                   ,minExtent
                   ,maxExtent
                   ,id
                   ,parameters->particleRadius
                   ,(void*)particles
                   ,callback_SPHDensityEstimator_i
                   ,(void*)&estDensity);

    density[id] = estDensity;
}

/**
 * For all particles p_i in particles, this kernel computes the density
 * constraint lambda value, defined as
 *
 *   \lambda_i = -C_i(p_1, ..., p_n) / \sum_k |\nabla(p_k) C_i|^2
 *
 * where,
 * 
 *   1) C_i(p_1, ..., p_n) = (\rho_i / \rho_0) - 1 = 0,
 *
 *   2) \rho_0 is the rest density, and
 *
 *   3) \rho_i is the density for particle p_i
 *
 * Specifically, this kernel computes lines (9) - (11) as part of the PBF 
 * algorithm
 *
 * NOTE:
 * This corresponds to Figure (1) in the section "Enforcing Incompressibility"
 *
 * @param [in]  Parameters* parameters Simulation parameters
 * @param [in]  const Particle* particles The particles in the simulation
 * @param [in]  const ParticlePosition* sortedParticleToCell
 * @param [in]  const GridCellOffset* gridCellOffsets
 * @param [in]  const float* density The density per particle. The i-th entry
 *              contains the density for the i-th particle
 * @param [in]  int numParticles The number of particles in the simulation
 * @param [in]  int cellsX The number of cells in the x axis of the spatial
 *              grid
 * @param [in]  int cellsY The number of cells in the y axis of the spatial
 *              grid
 * @param [in]  int cellsZ The number of cells in the z axis of the spatial
 *              grid
 * @param [in]  float3 minExtent The minimum extent of the simulation's
 *              bounding box in world space
 * @param [in]  float3 maxExtent The maximum extent of the simulation's
 *              bounding box in world space
 * @param [out] float* lambda The constraint lambda value
 */
kernel void computeLambda(const global Parameters* parameters
                         ,const global Particle* particles
                         ,const global ParticlePosition* sortedParticleToCell
                         ,const global GridCellOffset* gridCellOffsets
                         ,const global float* density
                         ,int numParticles
                         ,int cellsX
                         ,int cellsY
                         ,int cellsZ
                         ,float3 minExtent
                         ,float3 maxExtent
                         ,global float* lambda)
{
    int id = get_global_id(0);

    // Compute the constraint value C_i(p_1, ... p_n) for all neighbors [1..n]
    // of particle i:

    float C_i = (density[id] * INV_REST_DENSITY) - 1.0f;
    
    float gradientSum = 0.0f;
    
    // ==== Case (2) k = i =====================================================

    float4 gv_i = (float4)(0.0f, 0.0f, 0.0f, 0.0f);

    forAllNeighbors(parameters
                   ,particles
                   ,sortedParticleToCell
                   ,gridCellOffsets
                   ,numParticles
                   ,cellsX
                   ,cellsY
                   ,cellsZ
                   ,minExtent
                   ,maxExtent
                   ,id
                   ,parameters->particleRadius
                   ,(void*)particles
                   ,callback_SPHGradient_i
                   ,(void*)&gv_i);
    
    float gv_iLength = length(INV_REST_DENSITY * gv_i);
    
    gradientSum += (gv_iLength * gv_iLength);
    
    // ==== Case (2) k = j =====================================================
    
    float gv_sLengths = 0.0f;
    
    forAllNeighbors(parameters
                   ,particles
                   ,sortedParticleToCell
                   ,gridCellOffsets
                   ,numParticles
                   ,cellsX
                   ,cellsY
                   ,cellsZ
                   ,minExtent
                   ,maxExtent
                   ,id
                   ,parameters->particleRadius
                   ,(void*)particles
                   ,callback_SquaredSPHGradientLength_j
                   ,(void*)&gv_sLengths);
    
    gradientSum += gv_sLengths;
    
    // ==== lambda_i ===========================================================

    if (gradientSum == 0.0f) {
        gradientSum = EPSILON;
    }
    
    lambda[id] = -(C_i / ((gradientSum + parameters->relaxation)));
}

/**
 * For all particles p_i in particles, this kernel computes the position
 * delta of p_i, p_i*
 *
 * Specifically, this kernel computes line (13) as part of the PBF algorithm
 *
 * @param [in]     Parameters* parameters Simulation parameters
 * @param [in/out] Particle* particles The particles in the simulation
 * @param [in]  const ParticlePosition* sortedParticleToCell
 * @param [in]  const GridCellOffset* gridCellOffsets
 * @param [in]  const float* density The density per particle. The i-th entry
 *              contains the density for the i-th particle
 * @param [in]  int numParticles The number of particles in the simulation
 * @param [in]  int cellsX The number of cells in the x axis of the spatial
 *              grid
 * @param [in]  int cellsY The number of cells in the y axis of the spatial
 *              grid
 * @param [in]  int cellsZ The number of cells in the z axis of the spatial
 *              grid
 * @param [in]  float3 minExtent The minimum extent of the simulation's
 *              bounding box in world space
 * @param [in]  float3 maxExtent The maximum extent of the simulation's
 *              bounding box in world space
 * @param [out] float4* posDelta position changes
 */
kernel void computePositionDelta(const global Parameters* parameters
                                ,global Particle* particles
                                ,const global ParticlePosition* sortedParticleToCell
                                ,const global GridCellOffset* gridCellOffsets
                                ,int numParticles
                                ,const global float* lambda
                                ,int cellsX
                                ,int cellsY
                                ,int cellsZ
                                ,float3 minExtent
                                ,float3 maxExtent
                                ,global float4* posDelta)
{
    int id = get_global_id(0);
    global Particle *p = &particles[id];

    // The accumulated position delta, \delta p_i for the particle, p_i
    
    float4 posDelta_i = (float4)(0.0f, 0.0f, 0.0f, 1.0f);
    
    forAllNeighbors(parameters
                   ,particles
                   ,sortedParticleToCell
                   ,gridCellOffsets
                   ,numParticles
                   ,cellsX
                   ,cellsY
                   ,cellsZ
                   ,minExtent
                   ,maxExtent
                   ,id
                   ,parameters->particleRadius
                   ,(void*)lambda
                   ,callback_PositionDelta_i
                   ,(void*)&posDelta_i);
    
    posDelta[id] = INV_REST_DENSITY * posDelta_i;
    
    // Finally, clamp the particle's predicted position to the valid bounds
    // of the simulation:
    
    clampToBounds(parameters, p, minExtent, maxExtent);
}

/**
 * For all particles p_i in particles, this kernel tests for collisions between 
 * particles and objects/bounds and projects the positions of the particles 
 * accordingly
 *
 * Specifically, this kernel computes line (14) as part of the PBF algorithm
 *
 * @param [in]     Parameters* parameters Simulation parameters
 * @param [in/out] const Particle* particles The particles in the simulation
 * @param [in]     float3 minExtent The minimum extent of the simulation's
 *                 bounding box in world space
 * @param [in]     float3 maxExtent The maximum extent of the simulation's
 *                 bounding box in world space
 */
kernel void resolveCollisions(const global Parameters* parameters
                              ,global Particle* particles
                              ,float3 minExtent
                              ,float3 maxExtent)
{

}

/**
 * For all particles p_i in particles, this kernel applies the computed 
 * position delta to the predicted positions p_i.posStar.(x|y|z), e.g. "x_i*"
 * in the Position Based Fluids paper
 *
 * Specifically, this kernel computes line (16) - (18) as part of the PBF 
 * algorithm
 *
 * @param [in]  float4* posDelta The predicted delta position
 * @param [out] Particle* particles The particles in the simulation to be updated
 */
kernel void updatePositionDelta(const global float4* posDelta
                               ,global Particle* particles)
{
    int id = get_global_id(0);
    global Particle *p = &particles[id];
    
    p->posStar += posDelta[id];
}

/**
 * For all particles p_i in particles, this kernel computes the curl associated
 * with each particle
 *
 * @param [in]  Parameters* parameters Simulation parameters
 * @param [in]  const Particle* particles The particles in the simulation
 * @param [in]  const ParticlePosition* sortedParticleToCell
 * @param [in]  const GridCellOffset* gridCellOffsets
 * @param [in]  int numParticles The number of particles in the simulation
 * @param [in]  int cellsX The number of cells in the x axis of the spatial
 *              grid
 * @param [in]  int cellsY The number of cells in the y axis of the spatial
 *              grid
 * @param [in]  int cellsZ The number of cells in the z axis of the spatial
 *              grid
 * @param [in]  float3 minExtent The minimum extent of the simulation's
 *              bounding box in world space
 * @param [in]  float3 maxExtent The maximum extent of the simulation's
 *              bounding box in world space
 * @param [out] float4 curl The curl associated with each particle
 */
kernel void computeCurl(const global Parameters* parameters
                        ,const global Particle* particles
                        ,const global ParticlePosition* sortedParticleToCell
                        ,const global GridCellOffset* gridCellOffsets
                        ,int numParticles
                        ,int cellsX
                        ,int cellsY
                        ,int cellsZ
                        ,float3 minExtent
                        ,float3 maxExtent
                        ,global float4* curl)
{
    int id = get_global_id(0);
    
    // Curl for particle i:
    float4 omega_i = (float4)(0.0f, 0.0f, 0.0f, 0.0f);
    
    forAllNeighbors(parameters
                    ,particles
                    ,sortedParticleToCell
                    ,gridCellOffsets
                    ,numParticles
                    ,cellsX
                    ,cellsY
                    ,cellsZ
                    ,minExtent
                    ,maxExtent
                    ,id
                    ,parameters->particleRadius
                    ,(void*)particles
                    ,callback_Curl_i
                    ,(void*)&omega_i);
    
    curl[id] = omega_i;
}

/**
 * For all particles p_i in particles, this kernel computes the final
 * position of the particle
 *
 * Specifically, this kernel computes line (20) - (24) as part of the PBF
 * algorithm
 *
 * To do this, the following steps are applied to p_i:
 *
 * - Update v_i <- (1 / \delta t) * (x*_i - x_i) : line (21)
 * - Apply vorticity confinement to p_i          : line (22)
 * - Appl XSPH viscosity to p_i                  : line (22)
 * - Update x_i <- x*_i                          : line (23)
 *
 * @param [in]  Parameters* parameters Simulation parameters
 * @param [in]  const Particle* particles The particles in the simulation
 * @param [in]  const ParticlePosition* sortedParticleToCell
 * @param [in]  const GridCellOffset* gridCellOffsets
 * @param [in]  int numParticles The number of particles in the simulation
 * @param [in]  int cellsX The number of cells in the x axis of the spatial
 *              grid
 * @param [in]  int cellsY The number of cells in the y axis of the spatial
 *              grid
 * @param [in]  int cellsZ The number of cells in the z axis of the spatial
 *              grid
 * @param [in]  float3 minExtent The minimum extent of the simulation's
 *              bounding box in world space
 * @param [in]  float3 maxExtent The maximum extent of the simulation's
 *              bounding box in world space
 * @param [out] float4 curl The curl associated with each particle
 */
kernel void updatePosition(const global Parameters* parameters
                          ,float dt
                          ,global Particle* particles
                          ,const global ParticlePosition* sortedParticleToCell
                          ,const global GridCellOffset* gridCellOffsets
                          ,int numParticles
                          ,global float4* curl
                          ,int cellsX
                          ,int cellsY
                          ,int cellsZ
                          ,float3 minExtent
                          ,float3 maxExtent
                          ,global float4* renderPos)
{
    int id = get_global_id(0);
    global Particle *p = &particles[id];
    
    // Update the particle's final velocity based on the actual (x) and
    // predicted (x*) positions:
    
    p->vel = (1.0f / dt) * (p->posStar - p->pos);
    
    // ==== Apply vorticity confinement ========================================

    // Curl force for particle i:
    float4 omegaGradient = (float4)(0.0f, 0.0f, 0.0f, 0.0f);
    
    forAllNeighbors(parameters
                   ,particles
                   ,sortedParticleToCell
                   ,gridCellOffsets
                   ,numParticles
                   ,cellsX
                   ,cellsY
                   ,cellsZ
                   ,minExtent
                   ,maxExtent
                   ,id
                   ,parameters->particleRadius
                   ,(void*)curl
                   ,callback_Vorticity_i
                   ,(void*)&omegaGradient);
    
    float n = length(omegaGradient);
    float4 N = (float4)(0.0f, 0.0f, 0.0f, 0.0f);
    
    if (n > EPSILON) {
        N = normalize(omegaGradient);
    }
    
    float4 f_curl = parameters->vorticityEpsilon * cross(N, curl[id]);
    
    p->vel += (dt * f_curl);

    // ==== Apply XSPH viscosity ===============================================
    
    float4 v_i_sum = (float4)(0.0f, 0.0f, 0.0f, 0.0f);
    
    forAllNeighbors(parameters
                   ,particles
                   ,sortedParticleToCell
                   ,gridCellOffsets
                   ,numParticles
                   ,cellsX
                   ,cellsY
                   ,cellsZ
                   ,minExtent
                   ,maxExtent
                   ,id
                   ,parameters->particleRadius
                   ,(void*)particles
                   ,callback_XPSHViscosity_i
                   ,(void*)&v_i_sum);

    p->vel = p->vel + (parameters->viscosityCoeff * v_i_sum);
    
    // ==== Update position x_i <- x*_i ========================================

    // And finally the position:
    
    p->pos = p->posStar;
    
    renderPos[id] = p->pos;
    
    // We need this since we're using a 4 dimensional homogenous representation
    // of a 3D point, e.g. we need to show a point in (x,y,z), but our
    // representation is in (x,y,z,w), which OpenGL converts to
    // (x/w,y/z,z/w) so that it can be displayed in 3D. If w is zero, then
    // we'll never see any output, so if we set this explicitly to 1.0, then
    // everything will work correctly:
    
    renderPos[id].w = 1.0f;
}

