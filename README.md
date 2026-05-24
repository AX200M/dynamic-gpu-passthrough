
# Dynamic GPU Passthrough.

This repo was created to upload and maintain a viable and easy to use program / script that would automate the process of GPU passthrough for Linux users. 


## How to run.

To utilise the repo please follow these instructions:

**PLEASE NOTE THAT YOU NEED TO HAVE A VM ALREADY INSTALLED BEFORE RUNNING**

```bash
git clone https://github.com/AX200M/dynamic-gpu-passthrough.git
```

```bash
cd dynamic-gpu-passthrough
```

```bash
sudo chmod +x vfio-setup.sh
```

```bash
sudo ./vfio-setup.sh
```
## Tested Hardware
|Hardware | OS | Working |
|----------|----------|----------|
| CPU: Ryzen 9 9900x ( iGPU)  GPU: RX 9070XT | Fedora 44 (GNOME) | ✅ |

## DEMOS
Showcase of executing the manual binding and release files.
![ManualExec](https://raw.githubusercontent.com/AX200M/dynamic-gpu-passthrough/refs/heads/main/imgs/ManualExec.png)

Showcase of the script at work.
![DemoVid](https://github.com/AX200M/dynamic-gpu-passthrough/blob/main/vids/Demo.gif?raw=true)
