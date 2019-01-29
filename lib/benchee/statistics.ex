defmodule Benchee.Statistics do
  @moduledoc """
  Statistics related functionality that is meant to take the raw benchmark run
  times and then compute statistics like the average and the standard deviation.
  """

  alias Benchee.{Benchmark.Scenario, Conversion.Duration, Suite, Utility.Parallel}

  alias Benchee.Statistics.Mode
  alias Benchee.Statistics.Percentile
  require Integer

  defstruct [
    :average,
    :ips,
    :std_dev,
    :std_dev_ratio,
    :std_dev_ips,
    :median,
    :percentiles,
    :mode,
    :minimum,
    :maximum,
    sample_size: 0
  ]

  @type mode :: [number] | number | nil

  @type t :: %__MODULE__{
          average: float,
          ips: float | nil,
          std_dev: float,
          std_dev_ratio: float,
          std_dev_ips: float | nil,
          median: number,
          percentiles: %{number => float},
          mode: mode,
          minimum: number,
          maximum: number,
          sample_size: integer
        }

  @type samples :: [number]

  @doc """
  Takes a job suite with job run times, returns a map representing the
  statistics of the job suite as follows:

    * average       - average run time of the job in μs (the lower the better)
    * ips           - iterations per second, how often can the given function be
      executed within one second (the higher the better)
    * std_dev       - standard deviation, a measurement how much results vary
      (the higher the more the results vary)
    * std_dev_ratio - standard deviation expressed as how much it is relative to
      the average
    * std_dev_ips   - the absolute standard deviation of iterations per second
      (= ips * std_dev_ratio)
    * median        - when all measured times are sorted, this is the middle
      value (or average of the two middle values when the number of times is
      even). More stable than the average and somewhat more likely to be a
      typical value you see.
    * percentiles   - a map of percentile ranks. These are the values below
      which x% of the run times lie. For example, 99% of run times are shorter
      than the 99th percentile (99th %) rank.
      is a value for which 99% of the run times are shorter.
    * mode          - the run time(s) that occur the most. Often one value, but
      can be multiple values if they occur the same amount of times. If no value
      occurs at least twice, this value will be nil.
    * minimum       - the smallest (fastest) run time measured for the job
    * maximum       - the biggest (slowest) run time measured for the job
    * sample_size   - the number of run time measurements taken

  ## Parameters

  * `suite` - the job suite represented as a map after running the measurements,
    required to have the run_times available under the `run_times` key

  ## Examples

      iex> scenarios = [
      ...>   %Benchee.Benchmark.Scenario{
      ...>     job_name: "My Job",
      ...>     run_time_data: %Benchee.CollectionData{
      ...>       samples: [200, 400, 400, 400, 500, 500, 500, 700, 900]
      ...>     },
      ...>     memory_usage_data: %Benchee.CollectionData{
      ...>       samples: [200, 400, 400, 400, 500, 500, 500, 700, 900]
      ...>     },
      ...>     input_name: "Input",
      ...>     input: "Input"
      ...>   }
      ...> ]
      iex> suite = %Benchee.Suite{scenarios: scenarios}
      iex> Benchee.Statistics.statistics(suite)
      %Benchee.Suite{
        scenarios: [
          %Benchee.Benchmark.Scenario{
            job_name: "My Job",
            input_name: "Input",
            input: "Input",
            run_time_data: %Benchee.CollectionData{
              samples: [200, 400, 400, 400, 500, 500, 500, 700, 900],
              statistics: %Benchee.Statistics{
                average:       500.0,
                ips:           2000_000.0,
                std_dev:       200.0,
                std_dev_ratio: 0.4,
                std_dev_ips:   800_000.0,
                median:        500.0,
                percentiles:   %{50 => 500.0, 99 => 900.0},
                mode:          [500, 400],
                minimum:       200,
                maximum:       900,
                sample_size:   9
              }
            },
            memory_usage_data: %Benchee.CollectionData{
              samples: [200, 400, 400, 400, 500, 500, 500, 700, 900],
              statistics: %Benchee.Statistics{
                average:       500.0,
                ips:           nil,
                std_dev:       200.0,
                std_dev_ratio: 0.4,
                std_dev_ips:   nil,
                median:        500.0,
                percentiles:   %{50 => 500.0, 99 => 900.0},
                mode:          [500, 400],
                minimum:       200,
                maximum:       900,
                sample_size:   9
              }
            }
          }
        ],
        system: nil
      }

  """
  @spec statistics(Suite.t()) :: Suite.t()
  def statistics(suite = %Suite{scenarios: scenarios}) do
    config = suite.configuration

    percentiles = Enum.uniq([50 | config.percentiles])

    scenarios_with_statistics =
      Parallel.map(scenarios, fn scenario ->
        run_time_stats = scenario.run_time_data.samples |> job_statistics(percentiles) |> add_ips
        memory_stats = job_statistics(scenario.memory_usage_data.samples, percentiles)

        %{
          scenario
          | run_time_data: %{scenario.run_time_data | statistics: run_time_stats},
            memory_usage_data: %{scenario.memory_usage_data | statistics: memory_stats}
        }
      end)

    %Suite{suite | scenarios: sort(scenarios_with_statistics)}
  end

  @doc """
  Calculates statistical data based on a series of run times for a job
  in microseconds.

  ## Examples

      iex> run_times = [200, 400, 400, 400, 500, 500, 500, 700, 900]
      iex> Benchee.Statistics.job_statistics(run_times, [50, 99])
      %Benchee.Statistics{
        average:       500.0,
        ips:           nil,
        std_dev:       200.0,
        std_dev_ratio: 0.4,
        std_dev_ips:   nil,
        median:        500.0,
        percentiles:   %{50 => 500.0, 99 => 900.0},
        mode:          [500, 400],
        minimum:       200,
        maximum:       900,
        sample_size:   9
      }

      iex> Benchee.Statistics.job_statistics([100], [50, 99])
      %Benchee.Statistics{
        average:       100.0,
        ips:           nil,
        std_dev:       0,
        std_dev_ratio: 0.0,
        std_dev_ips:   nil,
        median:        100.0,
        percentiles:   %{50 => 100.0, 99 => 100.0},
        mode:          nil,
        minimum:       100,
        maximum:       100,
        sample_size:   1
      }

      iex> Benchee.Statistics.job_statistics([], [])
      %Benchee.Statistics{
        average:       nil,
        ips:           nil,
        std_dev:       nil,
        std_dev_ratio: nil,
        std_dev_ips:   nil,
        median:        nil,
        percentiles:   nil,
        mode:          nil,
        minimum:       nil,
        maximum:       nil,
        sample_size:   0
      }

  """
  @spec job_statistics(samples, list) :: __MODULE__.t()
  def job_statistics([], _) do
    %__MODULE__{sample_size: 0}
  end

  def job_statistics(measurements, percentiles) do
    total = Enum.sum(measurements)
    num_iterations = length(measurements)
    average = total / num_iterations
    deviation = standard_deviation(measurements, average, num_iterations)
    standard_dev_ratio = if average == 0, do: 0, else: deviation / average
    percentiles = Percentile.percentiles(measurements, percentiles)
    median = Map.fetch!(percentiles, 50)
    mode = Mode.mode(measurements)
    minimum = Enum.min(measurements)
    maximum = Enum.max(measurements)

    %__MODULE__{
      average: average,
      std_dev: deviation,
      std_dev_ratio: standard_dev_ratio,
      median: median,
      percentiles: percentiles,
      mode: mode,
      minimum: minimum,
      maximum: maximum,
      sample_size: num_iterations
    }
  end

  defp standard_deviation(_samples, _average, 1), do: 0

  defp standard_deviation(samples, average, sample_size) do
    total_variance =
      Enum.reduce(samples, 0, fn sample, total ->
        total + :math.pow(sample - average, 2)
      end)

    variance = total_variance / (sample_size - 1)
    :math.sqrt(variance)
  end

  defp add_ips(statistics = %__MODULE__{sample_size: 0}), do: statistics
  defp add_ips(statistics = %__MODULE__{average: 0.0}), do: statistics

  defp add_ips(statistics) do
    ips = Duration.convert_value({1, :second}, :nanosecond) / statistics.average
    standard_dev_ips = ips * statistics.std_dev_ratio

    %__MODULE__{
      statistics
      | ips: ips,
        std_dev_ips: standard_dev_ips
    }
  end

  @doc """
  Calculate additional percentiles and add them to the
  `run_time_data.statistics`. Should only be used after `statistics/1`, to
  calculate extra values that may be needed for reporting.

  ## Examples

  iex> scenarios = [
  ...>   %Benchee.Benchmark.Scenario{
  ...>     job_name: "My Job",
  ...>     run_time_data: %Benchee.CollectionData{
  ...>       samples: [200, 400, 400, 400, 500, 500, 500, 700, 900]
  ...>     },
  ...>     memory_usage_data: %Benchee.CollectionData{
  ...>       samples: [200, 400, 400, 400, 500, 500, 500, 700, 900]
  ...>     },
  ...>     input_name: "Input",
  ...>     input: "Input"
  ...>   }
  ...> ]
  iex> %Benchee.Suite{scenarios: scenarios}
  ...> |> Benchee.Statistics.statistics
  ...> |> Benchee.Statistics.add_percentiles([25, 75])
  %Benchee.Suite{
    scenarios: [
      %Benchee.Benchmark.Scenario{
        job_name: "My Job",
        input_name: "Input",
        input: "Input",
        run_time_data: %Benchee.CollectionData{
          samples: [200, 400, 400, 400, 500, 500, 500, 700, 900],
          statistics: %Benchee.Statistics{
            average:       500.0,
            ips:           2_000_000.0,
            std_dev:       200.0,
            std_dev_ratio: 0.4,
            std_dev_ips:   800_000.0,
            median:        500.0,
            percentiles:   %{25 => 400.0, 50 => 500.0, 75 => 600.0, 99 => 900.0},
            mode:          [500, 400],
            minimum:       200,
            maximum:       900,
            sample_size:   9
          }
        },
        memory_usage_data: %Benchee.CollectionData{
          samples: [200, 400, 400, 400, 500, 500, 500, 700, 900],
          statistics: %Benchee.Statistics{
            average:       500.0,
            ips:           nil,
            std_dev:       200.0,
            std_dev_ratio: 0.4,
            std_dev_ips:   nil,
            median:        500.0,
            percentiles:   %{50 => 500.0, 99 => 900.0},
            mode:          [500, 400],
            minimum:       200,
            maximum:       900,
            sample_size:   9
          }
        }
      }
    ]
  }
  """
  def add_percentiles(suite = %Suite{scenarios: scenarios}, percentile_ranks) do
    new_scenarios =
      Parallel.map(scenarios, fn scenario ->
        update_in(scenario.run_time_data.statistics.percentiles, fn existing ->
          new = Percentile.percentiles(scenario.run_time_data.samples, percentile_ranks)
          Map.merge(existing, new)
        end)
      end)

    %Suite{suite | scenarios: new_scenarios}
  end

  @spec sort([Scenario.t()]) :: [Scenario.t()]
  defp sort(scenarios) do
    Enum.sort_by(scenarios, fn scenario ->
      {scenario.run_time_data.statistics.average, scenario.memory_usage_data.statistics.average}
    end)
  end
end
