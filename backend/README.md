# Terraform Remote State

Bootstrap the backend once with local state:

```powershell
cd backend/bootstrap
terraform init
terraform apply
```

Copy the output values into `backend/backend.hcl`, then copy `backend/backend.tf.example` to the root as `backend.tf`.

Initialize the main stack with:

```powershell
cd ../..
terraform init -backend-config=backend/backend.hcl
```

Do not commit `backend.hcl` if it contains account-specific values that your team treats as private.
