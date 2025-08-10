from transformers import AutoTokenizer
import os
os.makedirs("assets/qwen-tokenizer", exist_ok=True)
tok = AutoTokenizer.from_pretrained("Qwen/Qwen2.5-3B-Instruct")
tok.save_pretrained("assets/qwen-tokenizer")
print("Saved:", os.listdir("assets/qwen-tokenizer"))
