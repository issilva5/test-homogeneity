
/**
 * Copyright 1993-2012 NVIDIA Corporation.  All rights reserved.
 *
 * Please refer to the NVIDIA end user license agreement (EULA) associated
 * with this source code for terms and conditions that govern your use of
 * this software. Any use, reproduction, disclosure, or distribution of
 * this software and related documentation outside the terms of the EULA
 * is strictly prohibited.
 */
#include <stdio.h>
#include <stdlib.h>
#include <tiffio.h>
#include <math.h>
#include <iostream>
#include <string.h>
#include <string>
#include <fstream>
#include <sstream>
#include <map>
#include <vector>
#include <algorithm>
#include <time.h>
#include <chrono>
#include <queue>
#include <set>
#include <cuda.h>

static const int WORK_SIZE = 256;
const int AGP = 14, PAS = 15, AGR = 18, CAP = 19, CSP = 20, MAP = 21;

#define CHECK_CUDA_RESULT(N) {											\
	CUresult result = N;												\
	if (result != 0) {													\
		printf("CUDA call on line %d returned error %d\n", __LINE__,	\
			result);													\
		exit(1);														\
	} }

void setup(TIFF* new_tif, int width, int length, int bitsPerSample, int sampleFormat){

    TIFFSetField(new_tif, TIFFTAG_IMAGEWIDTH     , width);
    TIFFSetField(new_tif, TIFFTAG_IMAGELENGTH    , length);
    TIFFSetField(new_tif, TIFFTAG_BITSPERSAMPLE  , bitsPerSample);
    TIFFSetField(new_tif, TIFFTAG_SAMPLEFORMAT   , sampleFormat);
    TIFFSetField(new_tif, TIFFTAG_COMPRESSION    , 1);
    TIFFSetField(new_tif, TIFFTAG_PHOTOMETRIC    , 1);
    TIFFSetField(new_tif, TIFFTAG_SAMPLESPERPIXEL, 1);
    TIFFSetField(new_tif, TIFFTAG_ROWSPERSTRIP   , 1);
    TIFFSetField(new_tif, TIFFTAG_RESOLUTIONUNIT , 1);
    TIFFSetField(new_tif, TIFFTAG_XRESOLUTION    , 1);
    TIFFSetField(new_tif, TIFFTAG_YRESOLUTION    , 1);
    TIFFSetField(new_tif, TIFFTAG_PLANARCONFIG   , PLANARCONFIG_CONTIG);

};

void write_line_tiff(TIFF* tif, double tif_line[], int line){

    if (TIFFWriteScanline(tif, tif_line, line) < 0){
        std::cerr << "Write problem!" << std::endl;
        exit(4);
    }

};

void write_line_tiff(TIFF* tif, int tif_line[], int line){

    if (TIFFWriteScanline(tif, tif_line, line) < 0){
        std::cerr << "Write problem!" << std::endl;
        exit(4);
    }

};

void read_line_tiff(TIFF* tif, double tif_line[], int line){
    if(TIFFReadScanline(tif, tif_line, line) < 0){
        std::cerr << "Read problem" << std::endl;
        exit(3);
    }
};

void read_line_tiff(TIFF* tif, int tif_line[], int line){
    if(TIFFReadScanline(tif, tif_line, line) < 0){
        std::cerr << "Read problem" << std::endl;
        exit(3);
    }
};

__host__ __device__ bool checkLandCode(int value){

    return (value == AGP) || (value == PAS) || (value == AGR) || (value == CAP) || (value == CSP) || (value == MAP);

}

__global__ void landCoverHomogeneity(double* inputBuffer, int* output, int line, int numCol, int numLine){

	int column = threadIdx.x + blockIdx.x * blockDim.x;
	double pixel_value;
	int aux;

	while (column < numCol) {

		aux = line % 7;

		pixel_value = inputBuffer[aux * numCol + column];

		output[column] = false;

		if(checkLandCode(pixel_value)) { //Verify if the pixel is an AGR pixel

			output[column] = true;

			for(int i = -3; i <= 3 && output[column]; i++){

				for(int j = -3; j <= 3 && output[column]; j++){

					// Check if the neighbor is AGR too

					if (column + i >= 0 && column + i < numCol && line + j >= 0 && line + j < numLine) {

						aux = (line + j) % 7;

						pixel_value = inputBuffer[aux * numCol + column];

						if(!isnan(pixel_value))
							if(!checkLandCode(pixel_value))
								output[column] = false;

					}

				}

			}

		}

		column += blockDim.x * gridDim.x;

	}

}

void testLandCoverHomogeneity(TIFF* landCover, TIFF* mask){

    uint32 height_band, width_band;
    TIFFGetField(landCover, TIFFTAG_IMAGELENGTH, &height_band);
    TIFFGetField(landCover, TIFFTAG_IMAGEWIDTH, &width_band);

    double* buffer = (double *) malloc(7 * width_band * sizeof(double));

    int relation[7] = {-1, -1, -1, -1, -1, -1, -1}, aux;

    for(int line = 0; line < height_band; line++) {

        // Create the respective line of the binary map of eligibles pixels
        int mask_line[width_band];

        for(int column = 0; column < width_band; column++) {

            int pixel_value;

            aux = line % 7;

            if(relation[aux] != line) {

                read_line_tiff(landCover, buffer + aux * width_band, line);
                relation[aux] = line;

            }

            pixel_value = buffer[aux * width_band + column];

            mask_line[column] = false;

            if(checkLandCode(pixel_value)) { //Verify if the pixel is an AGR pixel

                mask_line[column] = true;

                for(int i = -3; i <= 3 && mask_line[column]; i++){

                    for(int j = -3; j <= 3 && mask_line[column]; j++){

                        // Check if the neighbor is AGR too

                        if (column + i >= 0 && column + i < width_band && line + j >= 0 && line + j < height_band) {

                            aux = (line + j) % 7;

                            if(relation[aux] != (line + j)) {

                                read_line_tiff(landCover, buffer + aux * width_band, line + j);
                                relation[aux] = (line + j);

                            }

                            pixel_value = buffer[aux * width_band + column];

                            if(!std::isnan(pixel_value))
                                if(!checkLandCode(pixel_value))
                                    mask_line[column] = false;

                        }

                    }

                }

            }

        }

        write_line_tiff(mask, mask_line, line);

    }

//    for(int i = 0; i < 7; i++){
//        free(buffer[i]);
//    }
    free(buffer);

}

int main(int argc, char **argv) {

	std::string landCoverPath = argv[1];
	std::string outputPath = argv[2];

	std::string outputCPU = outputPath + "/CPU.tif";
	std::string outputGPU = outputPath + "/GPU.tif";

	TIFF* landCover = TIFFOpen(landCoverPath.c_str(), "rm");

	uint32 height_band, width_band;

	TIFFGetField(landCover, TIFFTAG_IMAGEWIDTH, &width_band);
	TIFFGetField(landCover, TIFFTAG_IMAGELENGTH, &height_band);

	TIFF* CPU = TIFFOpen(outputCPU.c_str(), "w8m");
	setup(CPU, width_band, height_band, 32, 2);

	testLandCoverHomogeneity(landCover, CPU);

	TIFFClose(CPU);

	TIFF* GPU = TIFFOpen(outputGPU.c_str(), "w8m");
	setup(GPU, width_band, height_band, 32, 2);

	double* buffer = (double *) malloc(7 * width_band * sizeof(double));
	int* output_line = (int*) malloc(width_band * sizeof(int));

	double* buffer_dev;
	cudaMalloc((void**) &buffer_dev, 7 * width_band * sizeof(double*));

	int* output_dev;
	cudaMalloc((void**) &output_dev, width_band * sizeof(int*));

	int relation[7] = {-1, -1, -1, -1, -1, -1, -1};

	for(int line = 0; line < height_band; line++) {

		for(int i = -3; i < 4; i++) {

			if(line + i >= 0 && line + i < height_band){

				if(relation[(line + i) % 7] != (line + i)) {
					read_line_tiff(landCover, buffer + ((line + i) % 7) * width_band, line + i);
					relation[(line + i) % 7] = line + i;
				}

			}

		}

		cudaMemcpy(buffer_dev, buffer, 7 * width_band * sizeof(double), cudaMemcpyHostToDevice);

		landCoverHomogeneity<<< (width_band + 1) / WORK_SIZE , WORK_SIZE>>>(buffer_dev, output_dev, line, width_band, height_band);

		cudaMemcpy(output_line, output_dev, width_band * sizeof(int), cudaMemcpyDeviceToHost);

		write_line_tiff(GPU, output_line, line);

	}

	free(buffer);
	free(output_line);
	cudaFree(buffer_dev);
	cudaFree(output_dev);

	TIFFClose(landCover);
	TIFFClose(GPU);

	return 0;
}
