defmodule Benchee.ConfigurationTest do
  use ExUnit.Case, async: true
  doctest Benchee.Configuration

  alias Benchee.{Configuration, Suite}

  import DeepMerge
  import Benchee.Configuration

  @default_config %Configuration{}

  describe "init/1" do
    test "crashes for values that are going to be ignored" do
      assert_raise KeyError, fn -> init(runntime: 2) end
    end

    test "converts inputs map to a list and input keys to strings" do
      assert %Suite{configuration: %{inputs: [{"list", []}, {"map", %{}}]}} =
               init(inputs: %{"map" => %{}, list: []})
    end

    test "doesn't convert input lists to maps and retains the order of input lists" do
      assert %Suite{configuration: %{inputs: [{"map", %{}}, {"list", []}]}} =
               init(inputs: [{"map", %{}}, {:list, []}])
    end

    test "loses duplicated inputs keys after normalization" do
      assert %Suite{configuration: %{inputs: [{"map", %{}}]}} =
               init(inputs: %{"map" => %{}, map: %{}})
    end

    test "uses information from :save to setup the external term formattter" do
      assert %Suite{
               configuration: %{
                 formatters: [
                   {Benchee.Formatters.Console, %{comparison: true, extended_statistics: false}},
                   {Benchee.Formatters.TaggedSave, %{path: "save_one.benchee", tag: "master"}}
                 ]
               }
             } = init(save: [path: "save_one.benchee", tag: "master"])
    end

    test ":save tag defaults to date" do
      assert %Suite{configuration: %{formatters: [_, {_, %{tag: tag, path: "save_one.benchee"}}]}} =
               init(save: [path: "save_one.benchee"])

      assert tag =~ ~r/\d\d\d\d-\d\d?-\d\d?--\d\d?-\d\d?-\d\d?/
    end
  end

  describe ".deep_merge behaviour" do
    test "it can be adjusted with a map" do
      user_options = %{time: 10}

      result = deep_merge(@default_config, user_options)

      expected = %Configuration{time: 10}

      assert expected == result
    end

    test "it just replaces when given another configuration" do
      other_config = %Configuration{}
      result = deep_merge(@default_config, other_config)
      expected = %Configuration{}

      assert ^expected = result
    end
  end
end
