//! Minimal C ABI around DeepFilterNet3 (libDF, tract backend, embedded model).
use df::tract::{DfParams, DfTract, RuntimeParams};
use ndarray::ArrayView2;
use std::slice;

pub struct Denoiser {
    model: DfTract,
}

/// Create a mono 48 kHz denoiser. `atten_lim_db` caps how much noise is removed (100 = unlimited).
#[no_mangle]
pub extern "C" fn df_new(atten_lim_db: f32) -> *mut Denoiser {
    let rt = RuntimeParams::default_with_ch(1).with_atten_lim(atten_lim_db);
    match DfTract::new(DfParams::default(), &rt) {
        Ok(model) => Box::into_raw(Box::new(Denoiser { model })),
        Err(_) => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "C" fn df_frame_len(d: *const Denoiser) -> usize {
    unsafe { (*d).model.hop_size }
}

#[no_mangle]
pub extern "C" fn df_sample_rate(d: *const Denoiser) -> usize {
    unsafe { (*d).model.sr }
}

#[no_mangle]
pub extern "C" fn df_set_atten_lim(d: *mut Denoiser, atten_lim_db: f32) {
    unsafe { (*d).model.set_atten_lim(atten_lim_db) }
}

/// Process exactly one hop (`df_frame_len` samples). Returns the model's local SNR estimate in dB.
#[no_mangle]
pub extern "C" fn df_process(d: *mut Denoiser, input: *const f32, output: *mut f32) -> f32 {
    unsafe {
        let d = &mut *d;
        let n = d.model.hop_size;
        let i = ArrayView2::from_shape((1, n), slice::from_raw_parts(input, n)).unwrap();
        let mut o = ndarray::Array2::<f32>::zeros((1, n));
        let lsnr = d.model.process(i, o.view_mut()).unwrap_or(0.0);
        slice::from_raw_parts_mut(output, n).copy_from_slice(o.as_slice().unwrap());
        lsnr
    }
}

#[no_mangle]
pub extern "C" fn df_free(d: *mut Denoiser) {
    if !d.is_null() {
        unsafe { drop(Box::from_raw(d)) }
    }
}
