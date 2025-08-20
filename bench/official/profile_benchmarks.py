#!/usr/bin/env python3
"""
Apple Instruments Profiler for Guillotine EVM Benchmarks

This script runs all benchmark cases through Apple's Instruments Time Profiler
to collect detailed CPU performance data including cache misses, branch
mispredictions, and execution hotspots.

Usage:
    python3 profile_benchmarks.py [--template TEMPLATE] [--output-dir DIR]

Requirements:
    - macOS with Xcode/Command Line Tools installed
    - hyperfine installed (brew install hyperfine)
    - Guillotine project built (zig build build-evm-runner)
"""

import subprocess
import os
import sys
import argparse
import json
from pathlib import Path
from typing import List, Dict, Optional
import time

class BenchmarkProfiler:
    def __init__(self, output_dir: str = "profile_results", template: str = "CPU Counters"):
        self.output_dir = Path(output_dir)
        self.template = template
        self.project_root = self._find_project_root()
        self.benchmark_cases = []
        
        # Ensure output directory exists
        self.output_dir.mkdir(exist_ok=True)
        
    def _find_project_root(self) -> Path:
        """Find the project root by looking for build.zig"""
        current = Path.cwd()
        for parent in [current] + list(current.parents):
            if (parent / "build.zig").exists():
                return parent
        raise RuntimeError("Could not find project root (no build.zig found)")
    
    def discover_benchmark_cases(self) -> List[Dict[str, str]]:
        """Discover all available benchmark cases"""
        cases_dir = self.project_root / "bench" / "official" / "cases"
        
        if not cases_dir.exists():
            raise RuntimeError(f"Benchmark cases directory not found: {cases_dir}")
        
        cases = []
        for case_dir in cases_dir.iterdir():
            if not case_dir.is_dir():
                continue
                
            bytecode_file = case_dir / "bytecode.txt"
            calldata_file = case_dir / "calldata.txt"
            
            if bytecode_file.exists() and calldata_file.exists():
                # Read calldata for the command
                with open(calldata_file, 'r') as f:
                    calldata = f.read().strip()
                
                cases.append({
                    'name': case_dir.name,
                    'bytecode_path': str(bytecode_file),
                    'calldata_path': str(calldata_file),
                    'calldata': calldata
                })
        
        return sorted(cases, key=lambda x: x['name'])
    
    def check_prerequisites(self) -> bool:
        """Check if all required tools are available"""
        checks = []
        
        # Check for xctrace (Instruments command line)
        try:
            subprocess.run(['xcrun', 'xctrace', 'version'], 
                         capture_output=True, check=True)
            checks.append(("✅ Instruments (xctrace)", True))
        except (subprocess.CalledProcessError, FileNotFoundError):
            checks.append(("❌ Instruments (xctrace) - Install Xcode Command Line Tools", False))
        
        # Check for hyperfine
        try:
            subprocess.run(['hyperfine', '--version'], 
                         capture_output=True, check=True)
            checks.append(("✅ hyperfine", True))
        except (subprocess.CalledProcessError, FileNotFoundError):
            checks.append(("❌ hyperfine - Install with: brew install hyperfine", False))
        
        # Check for evm-runner binary
        runner_path = self.project_root / "zig-out" / "bin" / "evm-runner"
        if runner_path.exists():
            checks.append(("✅ evm-runner binary", True))
        else:
            checks.append(("❌ evm-runner binary - Run: zig build build-evm-runner", False))
        
        print("Prerequisites check:")
        for message, status in checks:
            print(f"  {message}")
        
        return all(status for _, status in checks)
    
    def run_baseline_benchmark(self, case: Dict[str, str]) -> Optional[float]:
        """Run a baseline benchmark to get timing reference"""
        runner_path = self.project_root / "zig-out" / "bin" / "evm-runner"
        
        cmd = [
            'hyperfine',
            '--runs', '5',
            '--warmup', '2',
            '--export-json', '/tmp/baseline.json',
            f"{runner_path} --contract-code-path {case['bytecode_path']} --calldata {case['calldata']} --num-runs 1"
        ]
        
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, check=True)
            
            # Parse hyperfine results
            with open('/tmp/baseline.json', 'r') as f:
                data = json.load(f)
                if data['results']:
                    return data['results'][0]['mean'] * 1000  # Convert to ms
        except Exception as e:
            print(f"Warning: Could not get baseline timing for {case['name']}: {e}")
        
        return None
    
    def run_instruments_profile(self, case: Dict[str, str]) -> bool:
        """Run Instruments profiling for a single benchmark case"""
        print(f"\n🔍 Profiling {case['name']}...")
        
        # Get baseline timing first
        baseline_ms = self.run_baseline_benchmark(case)
        if baseline_ms:
            print(f"  Baseline timing: {baseline_ms:.2f}ms")
        
        runner_path = self.project_root / "zig-out" / "bin" / "evm-runner"
        output_file = self.output_dir / f"{case['name']}_profile.trace"
        
        # Build the command to profile
        target_cmd = [
            str(runner_path),
            '--contract-code-path', case['bytecode_path'],
            '--calldata', case['calldata'],
            '--num-runs', '100'  # Run multiple times for better profiling data
        ]
        
        # Build instruments command
        instruments_cmd = [
            'xcrun', 'xctrace', 'record',
            '--template', self.template,
            '--output', str(output_file),
            '--launch', '--'
        ] + target_cmd
        
        try:
            print(f"  Running: {' '.join(instruments_cmd)}")
            
            # Run with timeout to prevent hanging
            result = subprocess.run(
                instruments_cmd,
                capture_output=True,
                text=True,
                timeout=300,  # 5 minute timeout
                check=True
            )
            
            print(f"  ✅ Profile saved to: {output_file}")
            
            # Generate summary if possible
            self._generate_profile_summary(case['name'], output_file, baseline_ms)
            
            return True
            
        except subprocess.TimeoutExpired:
            print(f"  ❌ Timeout profiling {case['name']}")
            return False
        except subprocess.CalledProcessError as e:
            print(f"  ❌ Failed to profile {case['name']}: {e}")
            if e.stderr:
                print(f"  Error output: {e.stderr}")
            return False
    
    def _generate_profile_summary(self, case_name: str, trace_file: Path, baseline_ms: Optional[float]):
        """Generate a text summary of the profile data"""
        summary_file = self.output_dir / f"{case_name}_summary.txt"
        
        try:
            # Try to export some basic data from the trace
            export_cmd = [
                'xcrun', 'xctrace', 'export',
                '--input', str(trace_file),
                '--xpath', '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'
            ]
            
            result = subprocess.run(export_cmd, capture_output=True, text=True, timeout=30)
            
            with open(summary_file, 'w') as f:
                f.write(f"Profile Summary: {case_name}\n")
                f.write("=" * 50 + "\n\n")
                
                if baseline_ms:
                    f.write(f"Baseline timing: {baseline_ms:.2f}ms\n\n")
                
                f.write(f"Profile file: {trace_file}\n")
                f.write(f"Template used: {self.template}\n")
                f.write(f"Generated: {time.strftime('%Y-%m-%d %H:%M:%S')}\n\n")
                
                if result.returncode == 0 and result.stdout:
                    f.write("Profile data:\n")
                    f.write(result.stdout)
                else:
                    f.write("Raw profile data export failed - use Instruments.app to view detailed results\n")
                
                f.write(f"\nTo open in Instruments GUI:\n")
                f.write(f"open '{trace_file}'\n")
                
        except Exception as e:
            print(f"  Warning: Could not generate summary for {case_name}: {e}")
    
    def run_all_profiles(self):
        """Run Instruments profiling on all benchmark cases"""
        if not self.check_prerequisites():
            print("\n❌ Prerequisites not met. Please install missing tools.")
            return False
        
        # Discover benchmark cases
        self.benchmark_cases = self.discover_benchmark_cases()
        print(f"\n📊 Found {len(self.benchmark_cases)} benchmark cases:")
        for case in self.benchmark_cases:
            print(f"  - {case['name']}")
        
        print(f"\n🚀 Starting profiling with template: {self.template}")
        print(f"📁 Results will be saved to: {self.output_dir}")
        
        successful = 0
        failed = 0
        
        for i, case in enumerate(self.benchmark_cases, 1):
            print(f"\n[{i}/{len(self.benchmark_cases)}] Profiling {case['name']}")
            
            if self.run_instruments_profile(case):
                successful += 1
            else:
                failed += 1
        
        # Generate final report
        self._generate_final_report(successful, failed)
        
        print(f"\n🎯 Profiling complete!")
        print(f"  ✅ Successful: {successful}")
        print(f"  ❌ Failed: {failed}")
        print(f"  📁 Results in: {self.output_dir}")
        
        return failed == 0
    
    def _generate_final_report(self, successful: int, failed: int):
        """Generate a final HTML report with links to all profiles"""
        report_file = self.output_dir / "profile_report.html"
        
        html_content = f"""
<!DOCTYPE html>
<html>
<head>
    <title>Guillotine EVM Profile Report</title>
    <style>
        body {{ font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 40px; }}
        .header {{ background: #f5f5f5; padding: 20px; border-radius: 8px; margin-bottom: 30px; }}
        .case {{ margin: 20px 0; padding: 15px; border: 1px solid #ddd; border-radius: 5px; }}
        .success {{ border-left: 4px solid #28a745; }}
        .failed {{ border-left: 4px solid #dc3545; }}
        .stats {{ display: flex; gap: 20px; margin: 20px 0; }}
        .stat {{ background: #e9ecef; padding: 10px 15px; border-radius: 5px; }}
    </style>
</head>
<body>
    <div class="header">
        <h1>🔍 Guillotine EVM Benchmark Profiles</h1>
        <p>Generated on {time.strftime('%Y-%m-%d at %H:%M:%S')}</p>
        <p>Template: {self.template}</p>
    </div>
    
    <div class="stats">
        <div class="stat">✅ Successful: {successful}</div>
        <div class="stat">❌ Failed: {failed}</div>
        <div class="stat">📊 Total Cases: {len(self.benchmark_cases)}</div>
    </div>
    
    <h2>Profile Results</h2>
"""
        
        for case in self.benchmark_cases:
            trace_file = self.output_dir / f"{case['name']}_profile.trace"
            summary_file = self.output_dir / f"{case['name']}_summary.txt"
            
            status_class = "success" if trace_file.exists() else "failed"
            status_icon = "✅" if trace_file.exists() else "❌"
            
            html_content += f"""
    <div class="case {status_class}">
        <h3>{status_icon} {case['name']}</h3>
        <p><strong>Bytecode:</strong> {case['bytecode_path']}</p>
        <p><strong>Calldata:</strong> {case['calldata']}</p>
"""
            
            if trace_file.exists():
                html_content += f"""
        <p><strong>Actions:</strong></p>
        <ul>
            <li><a href="file://{trace_file}">Open in Instruments</a></li>
            <li><code>open '{trace_file}'</code></li>
"""
                if summary_file.exists():
                    html_content += f'            <li><a href="file://{summary_file}">View Summary</a></li>'
                
                html_content += "        </ul>"
            else:
                html_content += "        <p><em>Profile failed - check console output for errors</em></p>"
            
            html_content += "    </div>\n"
        
        html_content += """
    <h2>How to Use Profiles</h2>
    <ol>
        <li>Click "Open in Instruments" links above, or use the terminal commands</li>
        <li>In Instruments, examine the Time Profiler data:</li>
        <ul>
            <li><strong>Call Tree:</strong> Shows function call hierarchy and execution time</li>
            <li><strong>Sample List:</strong> Raw samples with stack traces</li>
            <li><strong>CPU Counters:</strong> Cache misses, branch mispredictions, etc.</li>
        </ul>
        <li>Look for hot spots in EVM execution functions</li>
        <li>Compare relative performance between benchmark cases</li>
    </ol>
    
    <h2>Additional Analysis</h2>
    <p>For detailed analysis, you can also run individual profiles with specific templates:</p>
    <pre>xcrun xctrace record --template "Allocations" --launch -- ./zig-out/bin/evm-runner ...</pre>
    <pre>xcrun xctrace record --template "Leaks" --launch -- ./zig-out/bin/evm-runner ...</pre>
</body>
</html>
"""
        
        with open(report_file, 'w') as f:
            f.write(html_content)
        
        print(f"  📄 HTML report generated: {report_file}")

def main():
    parser = argparse.ArgumentParser(description="Profile Guillotine EVM benchmarks with Apple Instruments")
    parser.add_argument('--template', default='CPU Counters', 
                       help='Instruments template to use (default: CPU Counters)')
    parser.add_argument('--output-dir', default='profile_results',
                       help='Output directory for profile results (default: profile_results)')
    parser.add_argument('--list-templates', action='store_true',
                       help='List available Instruments templates')
    
    args = parser.parse_args()
    
    if args.list_templates:
        print("Available Instruments templates:")
        try:
            result = subprocess.run(['xcrun', 'xctrace', 'list', 'templates'], 
                                  capture_output=True, text=True, check=True)
            print(result.stdout)
        except subprocess.CalledProcessError:
            print("Could not list templates - make sure Xcode Command Line Tools are installed")
        return
    
    profiler = BenchmarkProfiler(args.output_dir, args.template)
    success = profiler.run_all_profiles()
    
    sys.exit(0 if success else 1)

if __name__ == "__main__":
    main()