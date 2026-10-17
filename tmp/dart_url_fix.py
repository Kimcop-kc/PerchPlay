path = r"C:\Users\86177\Documents\deepseek-harness\default-workspace\video_player_app\lib\services\ai\ai_model_catalog.dart"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

prefix = "$_huggingfacePrefix"
subs = [
    (f"{prefix}/openai/whisper-large-v3-turbo", "https://huggingface.co/csukuangfj/sherpa-onnx-whisper-large-v3"),
    (f"{prefix}/google/gemma-3-1b-it", "https://huggingface.co/google/gemma-3-1b-it"),
    (f"{prefix}/Helsinki-NLP/opus-mt-zh-en", "https://huggingface.co/Helsinki-NLP/opus-mt-zh-en"),
    (f"{prefix}/google/madlad400-3b-mt", "https://huggingface.co/google/madlad400-3b-mt"),
    (f"{prefix}/BAAI/bge-small-zh-v1.5", "https://huggingface.co/BAAI/bge-small-zh-v1.5"),
    (f"{prefix}/BAAI/bge-m3", "https://huggingface.co/BAAI/bge-m3"),
    (f"{prefix}/RapidAI/RapidOCR", "https://huggingface.co/bluecopa/rapidocr-onnx"),
    (f"{prefix}/PaddlePaddle/PaddleOCR", "https://huggingface.co/aoiandroid/paddleocr-ppocrv5-onnx"),
    (f"{prefix}/idealo/image-quality-assessment", "https://huggingface.co/csukuangfj/sherpa-onnx-nemo-enc-dec-ctc-model"),
]

for old, new in subs:
    if old in content:
        content = content.replace(old, new)
        print("OK:", old[-50:])
    else:
        print("NOT FOUND:", old[-50:])

with open(path, "w", encoding="utf-8") as f:
    f.write(content)
print("Done")