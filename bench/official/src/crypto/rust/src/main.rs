use ark_bn254::{Bn254, Fq, Fq2, Fr, G1Affine, G1Projective, G2Affine, G2Projective};
use ark_ec::{pairing::Pairing, AffineRepr, CurveGroup, Group};
use ark_ff::{Field, UniformRand, Zero};
use ark_std::rand::{Rng, SeedableRng};
use ark_std::test_rng;
use std::env;
use std::time::Instant;

type G1 = G1Projective;
type G2 = G2Projective;

fn benchmark_fq_add(num_runs: usize) {
    let mut rng = test_rng();
    let mut inputs_a = Vec::with_capacity(num_runs);
    let mut inputs_b = Vec::with_capacity(num_runs);
    
    for _ in 0..num_runs {
        inputs_a.push(Fq::rand(&mut rng));
        inputs_b.push(Fq::rand(&mut rng));
    }

    let start = Instant::now();
    for i in 0..num_runs {
        let result = inputs_a[i] + inputs_b[i];
        std::hint::black_box(result);
    }
    let duration = start.elapsed();
    let avg_ns = duration.as_nanos() as u64 / num_runs as u64;
    println!("Fq.add: {}ns/op", avg_ns);
}

fn benchmark_fq_mul(num_runs: usize) {
    let mut rng = test_rng();
    let mut inputs_a = Vec::with_capacity(num_runs);
    let mut inputs_b = Vec::with_capacity(num_runs);
    
    for _ in 0..num_runs {
        inputs_a.push(Fq::rand(&mut rng));
        inputs_b.push(Fq::rand(&mut rng));
    }

    let start = Instant::now();
    for i in 0..num_runs {
        let result = inputs_a[i] * inputs_b[i];
        std::hint::black_box(result);
    }
    let duration = start.elapsed();
    let avg_ns = duration.as_nanos() as u64 / num_runs as u64;
    println!("Fq.mul: {}ns/op", avg_ns);
}

fn benchmark_fq2_mul(num_runs: usize) {
    let mut rng = test_rng();
    let mut inputs_a = Vec::with_capacity(num_runs);
    let mut inputs_b = Vec::with_capacity(num_runs);
    
    for _ in 0..num_runs {
        inputs_a.push(Fq2::rand(&mut rng));
        inputs_b.push(Fq2::rand(&mut rng));
    }

    let start = Instant::now();
    for i in 0..num_runs {
        let result = inputs_a[i] * inputs_b[i];
        std::hint::black_box(result);
    }
    let duration = start.elapsed();
    let avg_ns = duration.as_nanos() as u64 / num_runs as u64;
    println!("Fq2.mul: {}ns/op", avg_ns);
}

fn benchmark_fq6_mul(num_runs: usize) {
    let mut rng = test_rng();
    let mut inputs_a = Vec::with_capacity(num_runs);
    let mut inputs_b = Vec::with_capacity(num_runs);
    
    for _ in 0..num_runs {
        inputs_a.push(ark_bn254::Fq6::rand(&mut rng));
        inputs_b.push(ark_bn254::Fq6::rand(&mut rng));
    }

    let start = Instant::now();
    for i in 0..num_runs {
        let result = inputs_a[i] * inputs_b[i];
        std::hint::black_box(result);
    }
    let duration = start.elapsed();
    let avg_ns = duration.as_nanos() as u64 / num_runs as u64;
    println!("Fq6.mul: {}ns/op", avg_ns);
}

fn benchmark_fq12_mul(num_runs: usize) {
    let mut rng = test_rng();
    let mut inputs_a = Vec::with_capacity(num_runs);
    let mut inputs_b = Vec::with_capacity(num_runs);
    
    for _ in 0..num_runs {
        inputs_a.push(ark_bn254::Fq12::rand(&mut rng));
        inputs_b.push(ark_bn254::Fq12::rand(&mut rng));
    }

    let start = Instant::now();
    for i in 0..num_runs {
        let result = inputs_a[i] * inputs_b[i];
        std::hint::black_box(result);
    }
    let duration = start.elapsed();
    let avg_ns = duration.as_nanos() as u64 / num_runs as u64;
    println!("Fq12.mul: {}ns/op", avg_ns);
}

fn benchmark_g1_add(num_runs: usize) {
    let mut rng = test_rng();
    let mut inputs_a = Vec::with_capacity(num_runs);
    let mut inputs_b = Vec::with_capacity(num_runs);
    
    for _ in 0..num_runs {
        inputs_a.push(G1::rand(&mut rng));
        inputs_b.push(G1::rand(&mut rng));
    }

    let start = Instant::now();
    for i in 0..num_runs {
        let result = inputs_a[i] + inputs_b[i];
        std::hint::black_box(result);
    }
    let duration = start.elapsed();
    let avg_ns = duration.as_nanos() as u64 / num_runs as u64;
    println!("G1.add: {}ns/op", avg_ns);
}

fn benchmark_g1_mul(num_runs: usize) {
    let mut rng = test_rng();
    let mut inputs = Vec::with_capacity(num_runs);
    let mut scalars = Vec::with_capacity(num_runs);
    
    for _ in 0..num_runs {
        inputs.push(G1::rand(&mut rng));
        scalars.push(Fr::rand(&mut rng));
    }

    let start = Instant::now();
    for i in 0..num_runs {
        let result = inputs[i] * scalars[i];
        std::hint::black_box(result);
    }
    let duration = start.elapsed();
    let avg_ns = duration.as_nanos() as u64 / num_runs as u64;
    println!("G1.mul: {}ns/op", avg_ns);
}

fn benchmark_g2_add(num_runs: usize) {
    let mut rng = test_rng();
    let mut inputs_a = Vec::with_capacity(num_runs);
    let mut inputs_b = Vec::with_capacity(num_runs);
    
    for _ in 0..num_runs {
        inputs_a.push(G2::rand(&mut rng));
        inputs_b.push(G2::rand(&mut rng));
    }

    let start = Instant::now();
    for i in 0..num_runs {
        let result = inputs_a[i] + inputs_b[i];
        std::hint::black_box(result);
    }
    let duration = start.elapsed();
    let avg_ns = duration.as_nanos() as u64 / num_runs as u64;
    println!("G2.add: {}ns/op", avg_ns);
}

fn benchmark_g2_mul(num_runs: usize) {
    let mut rng = test_rng();
    let mut inputs = Vec::with_capacity(num_runs);
    let mut scalars = Vec::with_capacity(num_runs);
    
    for _ in 0..num_runs {
        inputs.push(G2::rand(&mut rng));
        scalars.push(Fr::rand(&mut rng));
    }

    let start = Instant::now();
    for i in 0..num_runs {
        let result = inputs[i] * scalars[i];
        std::hint::black_box(result);
    }
    let duration = start.elapsed();
    let avg_ns = duration.as_nanos() as u64 / num_runs as u64;
    println!("G2.mul: {}ns/op", avg_ns);
}

fn benchmark_pairing(num_runs: usize) {
    let mut rng = test_rng();
    let mut g1_inputs = Vec::with_capacity(num_runs);
    let mut g2_inputs = Vec::with_capacity(num_runs);
    
    for _ in 0..num_runs {
        g1_inputs.push(G1Affine::rand(&mut rng));
        g2_inputs.push(G2Affine::rand(&mut rng));
    }

    let start = Instant::now();
    for i in 0..num_runs {
        let result = Bn254::pairing(g1_inputs[i], g2_inputs[i]);
        std::hint::black_box(result);
    }
    let duration = start.elapsed();
    let avg_ns = duration.as_nanos() as u64 / num_runs as u64;
    println!("Pairing: {}ns/op", avg_ns);
}

fn main() {
    let args: Vec<String> = env::args().collect();
    
    if args.len() < 2 {
        eprintln!("Usage: {} <num_runs> [internal|external]", args[0]);
        return;
    }

    let num_runs: usize = args[1].parse().expect("Invalid number of runs");
    let is_external = args.len() > 2 && args[2] == "external";

    if is_external {
        benchmark_fq_add(num_runs);
        benchmark_fq_mul(num_runs);
        benchmark_fq2_mul(num_runs);
        benchmark_fq6_mul(num_runs);
        benchmark_fq12_mul(num_runs);
        benchmark_g1_add(num_runs);
        benchmark_g1_mul(num_runs);
        benchmark_g2_add(num_runs);
        benchmark_g2_mul(num_runs);
        benchmark_pairing(num_runs);
    } else {
        for _ in 0..num_runs {
            benchmark_fq_add(1000);
            benchmark_fq_mul(1000);
            benchmark_fq2_mul(500);
            benchmark_fq6_mul(100);
            benchmark_fq12_mul(50);
            benchmark_g1_add(200);
            benchmark_g1_mul(50);
            benchmark_g2_add(100);
            benchmark_g2_mul(25);
            benchmark_pairing(10);
        }
    }
}