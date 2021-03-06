package main

import (
	"fmt"
	"math"
	"time"

	"gonum.org/v1/gonum/stat/distuv"
)

const (
	day  = 24 * time.Hour
	year = 365 * day
)

func main() {
	// Create a normal distribution
	dist := distuv.Normal{
		Mu:    0,
		Sigma: 1,
	}

	var durations []time.Duration
	for i := time.Duration(1); i <= 60; i++ {
		durations = append(durations, i*time.Minute)
	}
	maxSigma := uint64(200)

	duration_array := "["
	for _, d := range durations {
		values := "["
		for s := uint64(0); s < maxSigma; s += 5 {
			values += fmt.Sprintf("%v,", calc(&dist, s, d))
		}
		values += fmt.Sprintf("%v]", calc(&dist, maxSigma, d))
		fmt.Printf("uint32[] private _cdf%v=%v;\n", uint64(d/time.Second), values)
		duration_array += fmt.Sprintf("%v,", uint64(d/time.Second))
	}

	for _, d := range durations {
		fmt.Printf("CDF[%v]=_cdf%v;\n", uint32(d/time.Second), uint32(d/time.Second))
	}

	fmt.Println(duration_array)
}

func calc(dist *distuv.Normal, s uint64, d time.Duration) uint32 {
	return uint32(1e9 * (2*dist.CDF(float64(s)*math.Sqrt(float64(d)/float64(year))/2/100) - 1))
}
