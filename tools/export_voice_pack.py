import argparse
import io
import json
import math
import os
import sys
import zipfile
import numpy as np
import soundfile as sf
import torch

def parse_args():
    parser = argparse.ArgumentParser(description="Export GPT-SoVITS v2/v2Pro models into a Yomiru Voice Pack (.yomiru-voice)")
    parser.add_argument("--gpt_sovits_root", type=str, default=r"D:\BaiduNetdiskDownload\GPT-SoVITS-v2pro-20250604", help="Path to GPT-SoVITS root")
    parser.add_argument("--gpt_path", type=str, required=True, help="Path to .ckpt file")
    parser.add_argument("--sovits_path", type=str, required=True, help="Path to .pth file")
    parser.add_argument("--ref_dir", type=str, required=True, help="Directory containing reference audio wavs")
    parser.add_argument("--output", type=str, default="ookura_resona.yomiru-voice", help="Output .yomiru-voice path")
    parser.add_argument("--voice_name", type=str, default="大藏衣远", help="Display name of the voice")
    parser.add_argument("--voice_id", type=str, default="ookura_resona", help="Voice identifier")
    parser.add_argument("--version", type=str, default="v2Pro", help="Model version (v2 or v2Pro)")
    parser.add_argument("--top_k", type=int, default=10, help="Default top_k")
    parser.add_argument("--top_p", type=float, default=0.75, help="Default top_p")
    parser.add_argument("--temperature", type=float, default=0.65, help="Default temperature")
    parser.add_argument("--speed", type=float, default=1.0, help="Default speed factor")
    return parser.parse_args()

def main():
    args = parse_args()
    root = os.path.abspath(args.gpt_sovits_root)
    os.chdir(root)
    sys.path.append(root)
    sys.path.append(os.path.join(root, "GPT_SoVITS"))

    # Apply ONNX export patches
    import AR.modules.patched_mha_with_cache_onnx as mha_mod
    import AR.modules.activation_onnx as act_mod
    import module.attentions_onnx as attn_onnx_mod
    import AR.models.t2s_model_onnx as t2s_onnx_mod

    # 1. Patch MHA unflatten and SDPA
    def custom_mha_forward_patched(query, key, value, embed_dim_to_check, num_heads, in_proj_weight, in_proj_bias, bias_k, bias_v, add_zero_attn, dropout_p, out_proj_weight, out_proj_bias, training=True, key_padding_mask=None, need_weights=True, attn_mask=None, use_separate_proj_weight=False, q_proj_weight=None, k_proj_weight=None, v_proj_weight=None, static_k=None, static_v=None, average_attn_weights=True, is_causal=False, cache=None):
        from torch.nn.functional import linear, _canonical_mask
        _, _, embed_dim = query.shape
        attn_mask = _canonical_mask(mask=attn_mask, mask_name="attn_mask", other_type=None, other_name="", target_type=query.dtype, check_other=False)
        head_dim = embed_dim // num_heads

        proj_qkv = linear(query, in_proj_weight, in_proj_bias)
        new_shape = (proj_qkv.shape[0], proj_qkv.shape[1], 3, query.size(-1))
        proj_qkv = proj_qkv.reshape(new_shape).permute(2, 0, 1, 3).contiguous()
        q, k, v = proj_qkv[0], proj_qkv[1], proj_qkv[2]

        if cache["first_infer"] == 1:
            cache["k"][cache["stage"]] = k
            cache["v"][cache["stage"]] = v
        else:
            cache["k"][cache["stage"]] = torch.cat([cache["k"][cache["stage"]][:-1], k], 0)
            cache["v"][cache["stage"]] = torch.cat([cache["v"][cache["stage"]][:-1], v], 0)
            k = cache["k"][cache["stage"]]
            v = cache["v"][cache["stage"]]
        cache["stage"] = (cache["stage"] + 1) % cache["all_stage"]

        attn_mask = _canonical_mask(mask=attn_mask, mask_name="attn_mask", other_type=None, other_name="", target_type=q.dtype, check_other=False)
        attn_mask = attn_mask.unsqueeze(0)

        q = q.view(-1, num_heads, head_dim).transpose(0, 1)
        k = k.view(-1, num_heads, head_dim).transpose(0, 1)
        v = v.view(-1, num_heads, head_dim).transpose(0, 1)

        attn_mask = attn_mask.unsqueeze(0)
        q = q.view(num_heads, -1, head_dim).unsqueeze(0)
        k = k.view(num_heads, -1, head_dim).unsqueeze(0)
        v = v.view(num_heads, -1, head_dim).unsqueeze(0)

        scores = torch.matmul(q, k.transpose(-2, -1)) / math.sqrt(head_dim)
        if attn_mask is not None:
            scores = scores + attn_mask
        weights = torch.softmax(scores, dim=-1)
        attn_output = torch.matmul(weights, v)

        attn_output = attn_output.permute(2, 0, 1, 3).contiguous().view(-1, embed_dim)
        attn_output = linear(attn_output, out_proj_weight, out_proj_bias)
        attn_output = attn_output.view(-1, 1, attn_output.size(1))
        return attn_output

    mha_mod.multi_head_attention_forward_patched = custom_mha_forward_patched
    act_mod.multi_head_attention_forward_patched = custom_mha_forward_patched

    # 2. Patch VITS relative embeddings slice bounds
    def custom_get_relative_embeddings(self, relative_embeddings, length):
        pad_l = length - (self.window_size + 1)
        pad_s = (self.window_size + 1) - length
        pad_length = torch.clamp(pad_l, min=0)
        slice_start_position = torch.clamp(pad_s, min=0)
        slice_end_position = slice_start_position + 2 * length - 1
        padded_relative_embeddings = torch.nn.functional.pad(relative_embeddings, (0, 0, pad_length, pad_length, 0, 0))
        used_relative_embeddings = padded_relative_embeddings[:, slice_start_position:slice_end_position]
        return used_relative_embeddings

    attn_onnx_mod.MultiHeadAttention._get_relative_embeddings = custom_get_relative_embeddings

    # 3. Patch top_k in t2s_model_onnx
    orig_logits_to_probs = t2s_onnx_mod.logits_to_probs
    def patched_logits_to_probs(logits, previous_tokens=None, temperature=1.0, top_k=None, top_p=None, repetition_penalty=1.0):
        if top_k is not None:
            top_k = int(top_k.item()) if isinstance(top_k, torch.Tensor) else int(top_k)
        return orig_logits_to_probs(logits, previous_tokens=previous_tokens, temperature=temperature, top_k=top_k, top_p=top_p, repetition_penalty=repetition_penalty)
    t2s_onnx_mod.logits_to_probs = patched_logits_to_probs

    from process_ckpt import load_sovits_new
    from module.models_onnx import SynthesizerTrn
    from AR.models.t2s_lightning_module_onnx import Text2SemanticLightningModule
    from TTS_infer_pack.TTS import TTS, TTS_Config

    temp_models_dir = os.path.join(os.path.dirname(os.path.abspath(args.output)), "_tmp_models")
    os.makedirs(temp_models_dir, exist_ok=True)

    print("Step 1: Loading weights & exporting ONNX models...")
    dict_s2 = load_sovits_new(args.sovits_path)
    config_s2 = dict_s2["config"]
    hps = config_s2["model"]
    hps["version"] = args.version
    hps["semantic_frame_rate"] = "25hz"

    vits_onnx = SynthesizerTrn(
        config_s2["data"]["filter_length"] // 2 + 1,
        config_s2["train"]["segment_size"] // config_s2["data"]["hop_length"],
        n_speakers=config_s2["data"]["n_speakers"],
        **hps
    )
    vits_onnx.eval()
    vits_onnx.load_state_dict(dict_s2["weight"], strict=False)

    dict_s1 = torch.load(args.gpt_path, map_location="cpu")
    config_s1 = dict_s1["config"]
    t2s_model = Text2SemanticLightningModule(config_s1, "ojbk", is_train=False)
    t2s_model.load_state_dict(dict_s1["weight"])
    t2s_model.eval()
    t2s_model.model.init_onnx()
    t2s_model.model.top_k = args.top_k
    t2s_model.model.first_stage_decoder.top_k = args.top_k
    t2s_model.model.stage_decoder.top_k = args.top_k

    class T2SEncoder(torch.nn.Module):
        def __init__(self, t2s, vits):
            super().__init__()
            self.encoder = t2s.onnx_encoder
            self.vits = vits
        def forward(self, ref_seq, text_seq, ref_bert, text_bert, ssl_content):
            codes = self.vits.extract_latent(ssl_content)
            prompt_semantic = codes[0, 0]
            bert = torch.cat([ref_bert.transpose(0, 1), text_bert.transpose(0, 1)], 1)
            all_phoneme_ids = torch.cat([ref_seq, text_seq], 1)
            return self.encoder(all_phoneme_ids, bert.unsqueeze(0)), prompt_semantic.unsqueeze(0)

    onnx_encoder = T2SEncoder(t2s_model.model, vits_onnx)
    ref_seq = torch.LongTensor([[229, 323, 96, 227, 160, 250]])
    text_seq = torch.LongTensor([[222, 229, 322, 64, 227]])
    ref_bert = torch.zeros((ref_seq.shape[1], 1024), dtype=torch.float32)
    text_bert = torch.zeros((text_seq.shape[1], 1024), dtype=torch.float32)
    ssl_content = torch.randn((1, 768, 50), dtype=torch.float32)

    enc_path = os.path.join(temp_models_dir, "t2s_encoder.onnx")
    fsdec_path = os.path.join(temp_models_dir, "t2s_fsdec.onnx")
    sdec_path = os.path.join(temp_models_dir, "t2s_sdec.onnx")
    vits_path_out = os.path.join(temp_models_dir, "vits.onnx")

    print("  -> Exporting t2s_encoder.onnx...")
    torch.onnx.export(onnx_encoder, (ref_seq, text_seq, ref_bert, text_bert, ssl_content), enc_path, input_names=["ref_seq", "text_seq", "ref_bert", "text_bert", "ssl_content"], output_names=["x", "prompts"], dynamic_axes={"ref_seq": {1: "ref_length"}, "text_seq": {1: "text_length"}, "ref_bert": {0: "ref_length"}, "text_bert": {0: "text_length"}, "ssl_content": {2: "ssl_length"}}, opset_version=16)

    x, prompts = onnx_encoder(ref_seq, text_seq, ref_bert, text_bert, ssl_content)
    print("  -> Exporting t2s_fsdec.onnx...")
    torch.onnx.export(t2s_model.model.first_stage_decoder, (x, prompts), fsdec_path, input_names=["x", "prompts"], output_names=["y", "k", "v", "y_emb", "x_example"], dynamic_axes={"x": {1: "x_length"}, "prompts": {1: "prompts_length"}}, verbose=False, opset_version=16)

    y, k, v, y_emb, x_example = t2s_model.model.first_stage_decoder(x, prompts)
    print("  -> Exporting t2s_sdec.onnx...")
    torch.onnx.export(t2s_model.model.stage_decoder, (y, k, v, y_emb, x_example), sdec_path, input_names=["iy", "ik", "iv", "iy_emb", "ix_example"], output_names=["y", "k", "v", "y_emb", "logits", "samples"], dynamic_axes={"iy": {1: "iy_length"}, "ik": {1: "ik_length"}, "iv": {1: "iv_length"}, "iy_emb": {1: "iy_emb_length"}, "ix_example": {1: "ix_example_length"}}, verbose=False, opset_version=16)

    print("  -> Exporting vits.onnx...")
    class VitsWrapper(torch.nn.Module):
        def __init__(self, v): super().__init__(); self.v = v
        def forward(self, p, t, r, s): return self.v(p, t, r, noise_scale=0.5, speed=1.0, sv_emb=s)
    torch.onnx.export(VitsWrapper(vits_onnx), (torch.randint(0, 1024, (1, 1, 80), dtype=torch.int64), torch.LongTensor([[222, 229, 322, 64, 227]]), torch.randn((1, 704, 100), dtype=torch.float32), torch.randn((1, 20480), dtype=torch.float32)), vits_path_out, input_names=["pred_semantic", "text", "refer", "sv_emb"], output_names=["audio"], dynamic_axes={"pred_semantic": {2: "semantic_length"}, "text": {1: "text_length"}, "refer": {2: "refer_length"}, "audio": {2: "audio_length"}}, opset_version=16)

    print("Step 2: Pre-extracting reference audio features (avoiding on-device heavy feature extractors)...")
    config_path = os.path.join(root, "GPT_SoVITS", "configs", "tts_infer.yaml")
    tts_config = TTS_Config(config_path)
    tts_config.t2s_weights_path = args.gpt_path
    tts_config.vits_weights_path = args.sovits_path
    tts_config.version = args.version
    pipeline = TTS(tts_config)

    ref_files = [f for f in os.listdir(args.ref_dir) if f.lower().endswith(".wav")]
    ref_entries = []

    voice_meta = {
        "version": "yomiru-voice-v1",
        "voice_id": args.voice_id,
        "name": args.voice_name,
        "model_version": args.version,
        "defaults": {
            "top_k": args.top_k,
            "top_p": args.top_p,
            "temperature": args.temperature,
            "speed": args.speed,
            "sample_rate": 32000,
        },
        "references": []
    }

    with zipfile.ZipFile(args.output, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        print(f"Step 3: Packing models into {args.output}...")
        zf.write(enc_path, "models/t2s_encoder.onnx")
        zf.write(fsdec_path, "models/t2s_fsdec.onnx")
        zf.write(sdec_path, "models/t2s_sdec.onnx")
        zf.write(vits_path_out, "models/vits.onnx")

        for w in ref_files:
            wav_path = os.path.join(args.ref_dir, w)
            name = w[:-4]
            tag = "default"
            prompt_text = name
            if "]" in name and name.startswith("["):
                tag = name[1:name.index("]")]
                prompt_text = name[name.index("]") + 1:]

            print(f"  -> Processing reference [{tag}] {prompt_text[:15]}...")
            with torch.no_grad():
                pipeline.set_ref_audio(wav_path)
                ref_spec, audio_tensor = pipeline.prompt_cache["refer_spec"][0]
                sv_emb = pipeline.sv_model.compute_embedding3(audio_tensor).float().detach().cpu().numpy()
                raw_audio = pipeline.prompt_cache["raw_audio"].to(pipeline.configs.device).to(pipeline.precision)
                ssl_content = pipeline.cnhuhbert_model.model(raw_audio)["last_hidden_state"].transpose(1, 2).float().detach().cpu().numpy()
                ref_phones, ref_bert, _ = pipeline.text_preprocessor.get_phones_and_bert(prompt_text, "ja", "v2")

            ref_id = f"ref_{tag}"
            zf.write(wav_path, f"references/{w}")

            # Save precomputed tensors
            spec_buf = io.BytesIO()
            np.save(spec_buf, ref_spec.float().detach().cpu().numpy())
            zf.writestr(f"features/{ref_id}_spec.npy", spec_buf.getvalue())

            sv_buf = io.BytesIO()
            np.save(sv_buf, sv_emb)
            zf.writestr(f"features/{ref_id}_sv.npy", sv_buf.getvalue())

            ssl_buf = io.BytesIO()
            np.save(ssl_buf, ssl_content)
            zf.writestr(f"features/{ref_id}_ssl.npy", ssl_buf.getvalue())

            voice_meta["references"].append({
                "id": ref_id,
                "tag": tag,
                "text": prompt_text,
                "lang": "ja",
                "wav": f"references/{w}",
                "spec": f"features/{ref_id}_spec.npy",
                "sv": f"features/{ref_id}_sv.npy",
                "ssl": f"features/{ref_id}_ssl.npy",
                "phones": ref_phones
            })

        print("Step 4: Writing voice.json...")
        zf.writestr("voice.json", json.dumps(voice_meta, ensure_ascii=False, indent=2))

    # Clean temporary models
    for p in [enc_path, fsdec_path, sdec_path, vits_path_out]:
        try: os.remove(p)
        except: pass
    try: os.rmdir(temp_models_dir)
    except: pass

    size_mb = os.path.getsize(args.output) / (1024 * 1024)
    print(f"\nSUCCESS! Voice Pack created at: {args.output} ({size_mb:.2f} MiB)")

if __name__ == "__main__":
    main()
