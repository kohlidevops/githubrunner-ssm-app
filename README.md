# GitHub Workflows to deploy the app on EC2 using Self-Hosted Runner with SSM Command
### Deploying application with SSM access (not SSH)


<img width="870" height="764" alt="image" src="https://github.com/user-attachments/assets/913ce434-cf44-4676-896b-21c05a98e04c" />


## Step 1 - AWS Infrastructure Setup

### Create VPC, Subnets, IGW and NAT Gateway

```
# Create VPC
aws ec2 create-vpc --cidr-block 10.0.0.0/16 \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=deploy-vpc}]'

# Save VPC ID
VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=deploy-vpc" \
  --query "Vpcs[0].VpcId" --output text)

# Public subnet
aws ec2 create-subnet --vpc-id $VPC_ID \
  --cidr-block 10.0.1.0/24 --availability-zone us-east-1a \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=public-subnet}]'

# Private subnet
aws ec2 create-subnet --vpc-id $VPC_ID \
  --cidr-block 10.0.2.0/24 --availability-zone us-east-1a \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=private-subnet}]'

# Internet Gateway
aws ec2 create-internet-gateway \
  --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=deploy-igw}]'

IGW_ID=$(aws ec2 describe-internet-gateways \
  --filters "Name=tag:Name,Values=deploy-igw" \
  --query "InternetGateways[0].InternetGatewayId" --output text)

aws ec2 attach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $IGW_ID

# Elastic IP for NAT
EIP=$(aws ec2 allocate-address --domain vpc --query AllocationId --output text)

PUBLIC_SUBNET=$(aws ec2 describe-subnets \
  --filters "Name=tag:Name,Values=public-subnet" \
  --query "Subnets[0].SubnetId" --output text)

# NAT Gateway
aws ec2 create-nat-gateway \
  --subnet-id $PUBLIC_SUBNET --allocation-id $EIP \
  --tag-specifications 'ResourceType=natgateway,Tags=[{Key=Name,Value=deploy-nat}]'

echo "VPC: $VPC_ID | Public: $PUBLIC_SUBNET | IGW: $IGW_ID"
```

### Route table

```
PRIVATE_SUBNET=$(aws ec2 describe-subnets \
  --filters "Name=tag:Name,Values=private-subnet" \
  --query "Subnets[0].SubnetId" --output text)

NAT_ID=$(aws ec2 describe-nat-gateways \
  --filter "Name=tag:Name,Values=deploy-nat" \
  --query "NatGateways[0].NatGatewayId" --output text)

# Public route table → IGW
PUBLIC_RT=$(aws ec2 create-route-table --vpc-id $VPC_ID \
  --query RouteTable.RouteTableId --output text)
aws ec2 create-route --route-table-id $PUBLIC_RT \
  --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
aws ec2 associate-route-table --subnet-id $PUBLIC_SUBNET --route-table-id $PUBLIC_RT

# Private route table → NAT
PRIVATE_RT=$(aws ec2 create-route-table --vpc-id $VPC_ID \
  --query RouteTable.RouteTableId --output text)
aws ec2 create-route --route-table-id $PRIVATE_RT \
  --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT_ID
aws ec2 associate-route-table --subnet-id $PRIVATE_SUBNET --route-table-id $PRIVATE_RT
```

### Security Groups

```
# Bastion SG — SSH from your IP only
BASTION_SG=$(aws ec2 create-security-group \
  --group-name bastion-sg --description "Bastion SSH" \
  --vpc-id $VPC_ID --query GroupId --output text)

MY_IP=$(curl -s ifconfig.me)
aws ec2 authorize-security-group-ingress \
  --group-id $BASTION_SG --protocol tcp --port 22 --cidr $MY_IP/32

# Runner SG — in public subnet, outbound HTTPS to GitHub
RUNNER_SG=$(aws ec2 create-security-group \
  --group-name runner-sg --description "Self-hosted runner" \
  --vpc-id $VPC_ID --query GroupId --output text)

aws ec2 authorize-security-group-ingress \
  --group-id $RUNNER_SG --protocol tcp --port 22 --source-group $BASTION_SG

# App EC2 SG — SSH from runner only
APP_SG=$(aws ec2 create-security-group \
  --group-name app-sg --description "App server" \
  --vpc-id $VPC_ID --query GroupId --output text)

aws ec2 authorize-security-group-ingress \
  --group-id $APP_SG --protocol tcp --port 22 --source-group $RUNNER_SG
aws ec2 authorize-security-group-ingress \
  --group-id $APP_SG --protocol tcp --port 8080 --source-group $RUNNER_SG

echo "Bastion SG: $BASTION_SG | Runner SG: $RUNNER_SG | App SG: $APP_SG"
```

### Launch EC2 Instances

```
# Generate SSH key pairs
aws ec2 create-key-pair --key-name bastion-key \
  --query KeyMaterial --output text > bastion-key.pem
chmod 400 bastion-key.pem

aws ec2 create-key-pair --key-name app-key \
  --query KeyMaterial --output text > app-key.pem
chmod 400 app-key.pem

aws ec2 create-key-pair --key-name runner-key \
  --query KeyMaterial --output text > runner-key.pem
chmod 400 runner-key.pem

AMI_ID="ami-0c101f26f147fa7fd"  # Amazon Linux 2023 us-east-1

# Bastion (public subnet, public IP)
aws ec2 run-instances \
  --image-id $AMI_ID --instance-type t3.micro \
  --key-name bastion-key --security-group-ids $BASTION_SG \
  --subnet-id $PUBLIC_SUBNET \
  --associate-public-ip-address \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=bastion}]'

# Runner (public subnet)
aws ec2 run-instances \
  --image-id $AMI_ID --instance-type t3.small \
  --key-name runner-key --security-group-ids $RUNNER_SG \
  --subnet-id $PUBLIC_SUBNET \
  --associate-public-ip-address \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=github-runner}]'

# App EC2 (private subnet, NO public IP)
aws ec2 run-instances \
  --image-id $AMI_ID --instance-type t3.small \
  --key-name app-key --security-group-ids $APP_SG \
  --subnet-id $PRIVATE_SUBNET \
  --no-associate-public-ip-address \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=app-server}]'
```

## Step 2 — GitHub Repository Structure

Create this project structure in your repo:

```
your-app/
├── .github/
│   └── workflows/
│       ├── deploy-ssm.yml          ← main deploy workflow
│       └── health-check.yml    ← optional post-deploy check
├── app/
│   ├── app.py                  ← your application
│   └── requirements.txt
├── scripts/
│   ├── deploy.sh               ← deployment script
│   └── health-check.sh
├── config/
│   └── app.env.example         ← env vars template (no secrets)
└── README.md
```

Clone the repo

```
https://github.com/kohlidevops/githubrunner-ssm-app.git
```

## Step 3 - Install GitHub Self-Hosted Runner on Runner EC2

```
# SSH into runner EC2
RUNNER_IP=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=github-runner" \
  --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

ssh -i runner-key.pem ec2-user@$RUNNER_IP
```

Once inside the runner EC2:

```
# Install dependencies
sudo yum update -y
sudo yum install -y git curl

# Create runner directory
mkdir -p /home/ec2-user/actions-runner && cd /home/ec2-user/actions-runner

# Download runner (get latest version from GitHub)
curl -o actions-runner-linux-x64.tar.gz -L \
  https://github.com/actions/runner/releases/download/v2.317.0/actions-runner-linux-x64-2.317.0.tar.gz

tar xzf actions-runner-linux-x64.tar.gz

# Configure runner — get token from:
# GitHub repo → Settings → Actions → Runners → New self-hosted runner
sudo ./bin/installdependencies.sh
sudo dnf install -y libicu
./config.sh \
  --url https://github.com/YOUR_USERNAME/YOUR_REPO \
  --token YOUR_RUNNER_TOKEN \
  --name aws-private-runner \
  --labels aws,private,production \
  --unattended

# Install as a service so it survives reboots
sudo ./svc.sh install
sudo ./svc.sh start
sudo ./svc.sh status
```
---
## Step 4 - GitHub Secrets Setup

Go to your repo → Settings → Secrets and variables → Actions → New repository secret

Add these secrets:


<img width="1379" height="659" alt="image" src="https://github.com/user-attachments/assets/68493047-c75b-4b9e-b770-1caf90025daf" />


## Step 5 - Workflow File

Create .github/workflows/deploy.yml: 

https://github.com/kohlidevops/githubrunner-ssm-app/blob/main/.github/workflows/deploy-ssm.yml

```
name: Deploy via SSM (No SSH Keys)

on:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  id-token: write    # required for OIDC
  contents: read

jobs:
  test:
    name: Run Tests
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: "3.11"

      - name: Install and test
        run: |
          pip install -r app/requirements.txt
          python -m pytest app/tests/ -v --tb=short

  deploy:
    name: Deploy via SSM
    runs-on: [self-hosted, aws, private]
    needs: test
    environment: production

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      # ── Authenticate to AWS via OIDC — no secrets needed ──────────────────
      - name: Configure AWS credentials via OIDC
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ${{ secrets.AWS_REGION }}
          role-session-name: GitHubDeploy-${{ github.run_id }}

      # ── Package and upload artifact to S3 ─────────────────────────────────
      - name: Package and upload to S3
        run: |
          ARTIFACT="app-${{ github.sha }}.tar.gz"
          tar -czf $ARTIFACT ./app/ ./scripts/

          aws s3 cp $ARTIFACT \
            s3://${{ secrets.S3_BUCKET }}/artifacts/$ARTIFACT

          # Also upload as latest for easy reference
          aws s3 cp $ARTIFACT \
            s3://${{ secrets.S3_BUCKET }}/artifacts/app-latest.tar.gz

          echo "ARTIFACT=$ARTIFACT" >> $GITHUB_ENV
          echo "Uploaded: s3://${{ secrets.S3_BUCKET }}/artifacts/$ARTIFACT"

      # ── Send deploy command to app EC2 via SSM ────────────────────────────
      - name: Deploy via SSM SendCommand
        run: |
          COMMAND_ID=$(aws ssm send-command \
            --instance-ids "${{ secrets.APP_INSTANCE_ID }}" \
            --document-name "AWS-RunShellScript" \
            --comment "Deploy ${{ github.sha }}" \
            --parameters commands="[
              \"set -e\",
              \"echo '=== Deploy started: $(date) ===' >> /home/ec2-user/deploy.log\",
              \"echo 'Commit: ${{ github.sha }}' >> /home/ec2-user/deploy.log\",
              \"cd /home/ec2-user\",
              \"aws s3 cp s3://${{ secrets.S3_BUCKET }}/artifacts/app-latest.tar.gz /tmp/app-latest.tar.gz\",
              \"mkdir -p /home/ec2-user/app\",
              \"tar -xzf /tmp/app-latest.tar.gz -C /home/ec2-user/\",
              \"chmod +x /home/ec2-user/scripts/*.sh\",
              \"APP_ENV=${{ secrets.APP_ENV }} bash /home/ec2-user/scripts/deploy.sh\",
              \"echo '=== Deploy complete: $(date) ===' >> /home/ec2-user/deploy.log\"
            ]" \
            --timeout-seconds 300 \
            --query "Command.CommandId" \
            --output text)

          echo "SSM Command ID: $COMMAND_ID"
          echo "COMMAND_ID=$COMMAND_ID" >> $GITHUB_ENV

      # ── Wait for SSM command to complete ──────────────────────────────────
      - name: Wait for SSM command
        run: |
          echo "Waiting for command $COMMAND_ID to complete..."

          for i in $(seq 1 30); do
            STATUS=$(aws ssm get-command-invocation \
              --command-id "$COMMAND_ID" \
              --instance-id "${{ secrets.APP_INSTANCE_ID }}" \
              --query "Status" \
              --output text 2>/dev/null || echo "Pending")

            echo "Attempt $i/30 — Status: $STATUS"

            if [ "$STATUS" = "Success" ]; then
              echo "✅ SSM command succeeded"
              break
            elif [ "$STATUS" = "Failed" ] || \
                 [ "$STATUS" = "Cancelled" ] || \
                 [ "$STATUS" = "TimedOut" ]; then
              echo "❌ SSM command failed with status: $STATUS"

              # Print the output for debugging
              aws ssm get-command-invocation \
                --command-id "$COMMAND_ID" \
                --instance-id "${{ secrets.APP_INSTANCE_ID }}" \
                --query "{stdout:StandardOutputContent,stderr:StandardErrorContent}" \
                --output json
              exit 1
            fi

            if [ "$i" -eq 30 ]; then
              echo "❌ Timed out waiting for SSM command"
              exit 1
            fi

            sleep 10
          done

      # ── Print SSM command output ───────────────────────────────────────────
      - name: Print deploy output
        if: always()
        run: |
          aws ssm get-command-invocation \
            --command-id "$COMMAND_ID" \
            --instance-id "${{ secrets.APP_INSTANCE_ID }}" \
            --query "{
              Status:Status,
              stdout:StandardOutputContent,
              stderr:StandardErrorContent
            }" \
            --output json

      # ── Health check via SSM ───────────────────────────────────────────────
      - name: Health check via SSM
        run: |
          HC_COMMAND_ID=$(aws ssm send-command \
            --instance-ids "${{ secrets.APP_INSTANCE_ID }}" \
            --document-name "AWS-RunShellScript" \
            --comment "Health check ${{ github.sha }}" \
            --parameters commands="[
              \"curl -sf http://localhost:8080/health || exit 1\",
              \"curl -sf http://localhost:8080/info || exit 1\",
              \"echo 'All health checks passed'\"
            ]" \
            --timeout-seconds 60 \
            --query "Command.CommandId" \
            --output text)

          sleep 10

          STATUS=$(aws ssm get-command-invocation \
            --command-id "$HC_COMMAND_ID" \
            --instance-id "${{ secrets.APP_INSTANCE_ID }}" \
            --query "Status" \
            --output text)

          if [ "$STATUS" = "Success" ]; then
            echo "✅ Health check passed"
          else
            echo "❌ Health check failed"
            aws ssm get-command-invocation \
              --command-id "$HC_COMMAND_ID" \
              --instance-id "${{ secrets.APP_INSTANCE_ID }}" \
              --query "{stdout:StandardOutputContent,stderr:StandardErrorContent}" \
              --output json
            exit 1
          fi

      - name: Deployment summary
        if: success()
        run: |
          echo "✅ Deployment successful"
          echo "   Commit  : ${{ github.sha }}"
          echo "   Actor   : ${{ github.actor }}"
          echo "   Artifact: s3://${{ secrets.S3_BUCKET }}/artifacts/${{ env.ARTIFACT }}"
```

## Step 6 - Deploy Script on App EC2

Create scripts/deploy.sh and scripts/health-check.sh

```
https://github.com/kohlidevops/githubrunner-ssm-app/tree/main/scripts
```

## Step 7 - Trigger and verify

```
# Push to main to trigger deploy
git add .
git commit -m "Initial deployment setup"
git push origin main
```

Then check:

1. GitHub → repo → Actions tab → watch the workflow run


<img width="1838" height="669" alt="image" src="https://github.com/user-attachments/assets/b78f82c5-9d76-4cfb-8343-94cb26bf3d68" />

3. Runner logs on EC2:

4. App healthcheck:

```
# From bastion EC2 (can reach private subnet)
curl http://10.0.2.xxx:8080/health
```

<img width="1038" height="463" alt="image" src="https://github.com/user-attachments/assets/60f2a5c7-9913-4150-aa4c-4f1b63fa0b69" />












