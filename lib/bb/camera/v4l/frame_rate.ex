# SPDX-FileCopyrightText: 2026 James Harton
#
# SPDX-License-Identifier: Apache-2.0

defmodule BB.Camera.V4L.FrameRate do
  @moduledoc """
  An exact frame rate, held as a rational.

  Video frame rates are rational numbers and some of the common ones are not
  representable in binary floating point: 30000/1001 is the NTSC rate, and
  rounding it to `29.97` is a different rate that drifts against the real one.
  V4L2 and ffmpeg both take a rational, so there is no reason to lose it on the
  way through.

  A rate can be given as a `Localize.Unit` in hertz (what the rest of the BB
  DSL uses), a bare positive number, or a `{numerator, denominator}` tuple when
  the exact rational matters:

      frame_rate: ~u(30 hertz)
      frame_rate: 30
      frame_rate: {30_000, 1001}

  Non-integer values are converted by scaling out the decimal digits and
  reducing, so `29.97` becomes `2997/100` — exactly the number that was
  written, not an approximation of something else. Ask for `{30_000, 1001}` if
  that is the rate you actually mean.
  """

  alias BB.Robot.Units
  alias Localize.Unit

  defstruct [:numerator, :denominator]

  @type t :: %__MODULE__{numerator: pos_integer(), denominator: pos_integer()}

  @type input :: Unit.t() | {pos_integer(), pos_integer()} | number()

  @doc """
  Build a frame rate from any of the accepted forms.

      iex> {:ok, rate} = BB.Camera.V4L.FrameRate.new({30_000, 1001})
      iex> BB.Camera.V4L.FrameRate.to_string(rate)
      "30000/1001"

      iex> {:ok, rate} = BB.Camera.V4L.FrameRate.new(30)
      iex> BB.Camera.V4L.FrameRate.to_string(rate)
      "30"

      iex> {:ok, rate} = BB.Camera.V4L.FrameRate.new(29.97)
      iex> BB.Camera.V4L.FrameRate.to_string(rate)
      "2997/100"

      iex> BB.Camera.V4L.FrameRate.new(0)
      {:error, :not_positive}

      iex> BB.Camera.V4L.FrameRate.new({30, 0})
      {:error, :not_positive}
  """
  @spec new(input() | t()) :: {:ok, t()} | {:error, :not_positive | :not_a_frame_rate}
  def new(%__MODULE__{} = rate), do: {:ok, rate}

  def new(%Unit{} = unit) do
    unit
    |> Unit.convert!("hertz")
    |> Units.extract_float()
    |> new()
  end

  def new({numerator, denominator})
      when is_integer(numerator) and is_integer(denominator) do
    if numerator > 0 and denominator > 0 do
      {:ok, reduce(numerator, denominator)}
    else
      {:error, :not_positive}
    end
  end

  def new(value) when is_integer(value), do: new({value, 1})

  def new(value) when is_float(value) do
    cond do
      value <= 0.0 -> {:error, :not_positive}
      value == Float.round(value) -> new({trunc(value), 1})
      true -> from_decimal(value)
    end
  end

  def new(_other), do: {:error, :not_a_frame_rate}

  @doc """
  Build a frame rate, raising on anything that is not one.
  """
  @spec new!(input() | t()) :: t() | no_return()
  def new!(input) do
    case new(input) do
      {:ok, rate} -> rate
      {:error, reason} -> raise ArgumentError, "invalid frame rate: #{reason}"
    end
  end

  @doc """
  The rate as a float, for reporting.

      iex> BB.Camera.V4L.FrameRate.to_float(BB.Camera.V4L.FrameRate.new!({30_000, 1001}))
      29.97002997002997
  """
  @spec to_float(t()) :: float()
  def to_float(%__MODULE__{numerator: numerator, denominator: denominator}),
    do: numerator / denominator

  @doc """
  The rate in the `num/den` form ffmpeg and V4L2 accept.
  """
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{numerator: numerator, denominator: 1}),
    do: Integer.to_string(numerator)

  def to_string(%__MODULE__{numerator: numerator, denominator: denominator}),
    do: "#{numerator}/#{denominator}"

  @doc """
  A `Spark.Options` type accepting every form of `t:input/0`.
  """
  @spec option_type() :: {:custom, module(), atom(), [term()]}
  def option_type, do: {:custom, __MODULE__, :validate, []}

  @doc false
  @spec validate(term()) :: {:ok, t()} | {:error, String.t()}
  def validate(%__MODULE__{} = rate), do: {:ok, rate}

  def validate(input) do
    case new(input) do
      {:ok, rate} ->
        {:ok, rate}

      {:error, :not_positive} ->
        {:error, "expected a positive frame rate, got: #{inspect(input)}"}

      {:error, :not_a_frame_rate} ->
        {:error,
         "expected a frame rate as a hertz unit, a positive number, or a " <>
           "{numerator, denominator} tuple, got: #{inspect(input)}"}
    end
  end

  defp from_decimal(value) do
    [_whole, fraction] =
      value
      |> :erlang.float_to_binary([:short])
      |> String.split(".")

    scale = Integer.pow(10, byte_size(fraction))

    {:ok, reduce(round(value * scale), scale)}
  end

  defp reduce(numerator, denominator) do
    divisor = Integer.gcd(numerator, denominator)

    %__MODULE__{numerator: div(numerator, divisor), denominator: div(denominator, divisor)}
  end
end
