use ark_bn254::{Bn254, Fq, Fq2, Fr, G1Affine, G1Projective, G2Affine, G2Projective};
use ark_ec::pairing::Pairing;
use ark_ff::UniformRand;
use ark_std::test_rng;
use std::time::Instant;
use clap::{Arg, Command};

type G1 = G1Projective;
type G2 = G2Projective;

fn benchmark_operation(operation: &str, internal_runs: usize) -> f64 {
    let mut rng = test_rng();
    
    let start = match operation {
        "FpMont.add" => {
            let mut inputs_a = Vec::with_capacity(internal_runs);
            let mut inputs_b = Vec::with_capacity(internal_runs);
            
            for _ in 0..internal_runs {
                inputs_a.push(Fq::rand(&mut rng));
                inputs_b.push(Fq::rand(&mut rng));
            }

            let start = Instant::now();
            for i in 0..internal_runs {
                let result = inputs_a[i] + inputs_b[i];
                std::hint::black_box(result);
            }
            start
        }
        "FpMont.mul" => {
            let mut inputs_a = Vec::with_capacity(internal_runs);
            let mut inputs_b = Vec::with_capacity(internal_runs);
            
            for _ in 0..internal_runs {
                inputs_a.push(Fq::rand(&mut rng));
                inputs_b.push(Fq::rand(&mut rng));
            }

            let start = Instant::now();
            for i in 0..internal_runs {
                let result = inputs_a[i] * inputs_b[i];
                std::hint::black_box(result);
            }
            start
        }
        "Fp2Mont.mul" => {
            let mut inputs_a = Vec::with_capacity(internal_runs);
            let mut inputs_b = Vec::with_capacity(internal_runs);
            
            for _ in 0..internal_runs {
                inputs_a.push(Fq2::rand(&mut rng));
                inputs_b.push(Fq2::rand(&mut rng));
            }

            let start = Instant::now();
            for i in 0..internal_runs {
                let result = inputs_a[i] * inputs_b[i];
                std::hint::black_box(result);
            }
            start
        }
        "Fp6Mont.mul" => {
            let mut inputs_a = Vec::with_capacity(internal_runs);
            let mut inputs_b = Vec::with_capacity(internal_runs);
            
            for _ in 0..internal_runs {
                inputs_a.push(ark_bn254::Fq6::rand(&mut rng));
                inputs_b.push(ark_bn254::Fq6::rand(&mut rng));
            }

            let start = Instant::now();
            for i in 0..internal_runs {
                let result = inputs_a[i] * inputs_b[i];
                std::hint::black_box(result);
            }
            start
        }
        "Fp12Mont.mul" => {
            let mut inputs_a = Vec::with_capacity(internal_runs);
            let mut inputs_b = Vec::with_capacity(internal_runs);
            
            for _ in 0..internal_runs {
                inputs_a.push(ark_bn254::Fq12::rand(&mut rng));
                inputs_b.push(ark_bn254::Fq12::rand(&mut rng));
            }

            let start = Instant::now();
            for i in 0..internal_runs {
                let result = inputs_a[i] * inputs_b[i];
                std::hint::black_box(result);
            }
            start
        }
        "G1.add" => {
            let mut inputs_a = Vec::with_capacity(internal_runs);
            let mut inputs_b = Vec::with_capacity(internal_runs);
            
            for _ in 0..internal_runs {
                inputs_a.push(G1::rand(&mut rng));
                inputs_b.push(G1::rand(&mut rng));
            }

            let start = Instant::now();
            for i in 0..internal_runs {
                let result = inputs_a[i] + inputs_b[i];
                std::hint::black_box(result);
            }
            start
        }
        "G1.mul" => {
            let mut inputs = Vec::with_capacity(internal_runs);
            let mut scalars = Vec::with_capacity(internal_runs);
            
            for _ in 0..internal_runs {
                inputs.push(G1::rand(&mut rng));
                scalars.push(Fr::rand(&mut rng));
            }

            let start = Instant::now();
            for i in 0..internal_runs {
                let result = inputs[i] * scalars[i];
                std::hint::black_box(result);
            }
            start
        }
        "G2.add" => {
            let mut inputs_a = Vec::with_capacity(internal_runs);
            let mut inputs_b = Vec::with_capacity(internal_runs);
            
            for _ in 0..internal_runs {
                inputs_a.push(G2::rand(&mut rng));
                inputs_b.push(G2::rand(&mut rng));
            }

            let start = Instant::now();
            for i in 0..internal_runs {
                let result = inputs_a[i] + inputs_b[i];
                std::hint::black_box(result);
            }
            start
        }
        "G2.mul" => {
            let mut inputs = Vec::with_capacity(internal_runs);
            let mut scalars = Vec::with_capacity(internal_runs);
            
            for _ in 0..internal_runs {
                inputs.push(G2::rand(&mut rng));
                scalars.push(Fr::rand(&mut rng));
            }

            let start = Instant::now();
            for i in 0..internal_runs {
                let result = inputs[i] * scalars[i];
                std::hint::black_box(result);
            }
            start
        }
        "Pairing" => {
            let mut g1_inputs = Vec::with_capacity(internal_runs);
            let mut g2_inputs = Vec::with_capacity(internal_runs);
            
            for _ in 0..internal_runs {
                g1_inputs.push(G1Affine::rand(&mut rng));
                g2_inputs.push(G2Affine::rand(&mut rng));
            }

            let start = Instant::now();
            for i in 0..internal_runs {
                let result = Bn254::pairing(g1_inputs[i], g2_inputs[i]);
                std::hint::black_box(result);
            }
            start
        }
        _ => {
            eprintln!("Error: Unknown operation '{}'", operation);
            std::process::exit(1);
        }
    };
    
    let duration = start.elapsed();
    duration.as_secs_f64() * 1000.0 // Convert to milliseconds
}

fn main() {
    let matches = Command::new("rust-crypto-bench")
        .version("1.0")
        .about("Benchmarks crypto operations using arkworks")
        .arg(
            Arg::new("operation")
                .long("operation")
                .value_name("OPERATION")
                .help("The operation to benchmark")
                .required(true)
                .value_parser([
                    "FpMont.add", "FpMont.mul", "Fp2Mont.mul", "Fp6Mont.mul", 
                    "Fp12Mont.mul", "G1.add", "G1.mul", "G2.add", "G2.mul", "Pairing"
                ])
        )
        .arg(
            Arg::new("num-runs")
                .long("num-runs")
                .value_name("RUNS")
                .help("Number of runs to perform")
                .required(true)
        )
        .get_matches();

    let operation = matches.get_one::<String>("operation").unwrap();
    let num_runs: u32 = matches.get_one::<String>("num-runs").unwrap()
        .parse()
        .expect("Invalid number of runs");

    // Internal runs scaled based on operation complexity for consistent ~10ms timing
    // These values are tuned to match Zig performance characteristics
    let internal_runs: usize = match operation.as_str() {
        "FpMont.add" => 400000,    // Rust is faster, needs more runs
        "FpMont.mul" => 200000,
        "Fp2Mont.mul" => 100000,
        "Fp6Mont.mul" => 20000,
        "Fp12Mont.mul" => 10000,
        "G1.add" => 40000,
        "G1.mul" => 2000,
        "G2.add" => 20000,
        "G2.mul" => 800,
        "Pairing" => 200,
        _ => 1000,
    };

    // Run benchmark num_runs times, outputting timing in milliseconds for each run
    for _ in 0..num_runs {
        let elapsed_ms = benchmark_operation(operation, internal_runs);
        println!("{:.6}", elapsed_ms);
    }
}