Task: Filter and analyze a recorded sensor signal

Implement a Python script that loads the signal from data/input_signal.csv, where the columns are time and amplitude.

The script should:

    Estimate the sampling frequency from the time column.
    Plot the raw signal.
    Apply a fourth-order low-pass Butterworth filter with a 20 Hz cutoff.
    Plot the raw and filtered signals together.
    Compute and report the signal duration, mean, minimum, maximum, and dominant frequency.
    Generate and save an FFT magnitude plot.

    Save the filtered data to output/filtered_signal.csv.

Use NumPy, Pandas, SciPy, and Matplotlib. Keep the filtering logic in reusable functions and add basic validation for missing files, invalid columns, and insufficient data.

Acceptance criteria:

    Running python signal_analysis.py completes without errors using the provided input file.
    The filtered output preserves the original time values.
    The output CSV contains time and filtered_amplitude columns.
    The script produces the requested plots and summary statistics.
    Include a short README with installation and usage instructions.