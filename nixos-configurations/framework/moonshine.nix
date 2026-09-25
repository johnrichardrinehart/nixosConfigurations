{ lib, ... }:
{
  nixpkgs.overlays = lib.mkAfter [
    (_final: prev: {
      dev = prev.dev // {
        johnrinehart = prev.dev.johnrinehart // {
          moonshine-models-onnx = prev.dev.johnrinehart.moonshine-models-onnx.overrideAttrs (old: {
            postBuild = (old.postBuild or "") + ''
              python3 - <<'PY'
              import os
              from pathlib import Path
              import onnxruntime as ort

              work = Path(os.environ["TMPDIR"])
              frontend = work / "out/frontend.onnx"
              weights = work / "out/frontend.weights.onnx"
              options = ort.SessionOptions()
              options.optimized_model_filepath = str(weights)
              options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_BASIC
              ort.InferenceSession(work / "models/frontend.weights.ort", options, providers=["CPUExecutionProvider"])

              front_inputs = {item.name: tuple(item.shape) for item in ort.InferenceSession(frontend, providers=["CPUExecutionProvider"]).get_inputs()}
              weight_session = ort.InferenceSession(weights, providers=["CPUExecutionProvider"])
              weight_outputs = {item.name: tuple(item.shape) for item in weight_session.get_outputs()}
              required = set(front_inputs) - {"audio_chunk", "sample_buffer", "sample_len", "conv1_buffer", "conv2_buffer", "frame_count"}
              if not required or required != set(weight_outputs) or any(front_inputs[name] != weight_outputs[name] for name in required):
                  raise ValueError("Frontend split weights do not satisfy its model inputs")
              if len(weight_session.run(None, {})) != len(required):
                  raise ValueError("Frontend split weights did not load")
              PY
            '';
          });
          libmoonshine = prev.dev.johnrinehart.libmoonshine.overrideAttrs (old: {
            postPatch = (old.postPatch or "") + ''
              # The converted streaming models are ONNX, not ORT flatbuffers.
              substituteInPlace moonshine-streaming-model.cpp \
                --replace-fail 'ort_configure_ort_file_session(ort_api, ort_session_options);' \
                'LOG_ORT_ERROR(ort_api, ort_api->SetSessionGraphOptimizationLevel(ort_session_options, ORT_ENABLE_ALL));'
              # The split pair uses the exported frontend and weights filenames.
              substituteInPlace moonshine-streaming-model.cpp \
                --replace-fail '"frontend.model.ort"' '"frontend.onnx"' \
                --replace-fail '"frontend.weights.ort"' '"frontend.weights.onnx"'
            '';
          });
        };
      };
    })
  ];
}
